# frozen_string_literal: true

namespace :ops do
  def load_tenant!(write: false)
    tenant_id = ENV['TENANT_ID']
    if write && tenant_id.blank?
      raise 'This task WRITES to tenant data and requires explicit TENANT_ID (e.g. TENANT_ID=<tenant id> bin/rails <task>)'
    end

    tenant = tenant_id.present? ? Tenant.find_by(id: tenant_id) : Tenant.where(status: 'active').first
    raise 'No tenant found (set TENANT_ID or seed one)' if tenant.nil?

    Current.tenant = tenant
  end

  desc 'Run a full Shopify + Square sync'
  task sync: :environment do
    load_tenant!
    SyncEngine.run!(mode: 'manual', actor: 'rake')
    puts 'Sync completed'
  end

  desc 'Backfill order history: ops:backfill[DAYS] (defaults to SYNC_HISTORY_DAYS or 3650)'
  task :backfill, [:days] => :environment do |_, args|
    load_tenant!
    days = (args[:days] || ENV['SYNC_HISTORY_DAYS'] || '3650').to_i
    SyncEngine.run!(mode: 'backfill', actor: 'rake', history_days: days)
    puts "Backfill completed (#{days} days)"
  end

  desc 'Run a single-source sync: ops:sync_source[shopify|square]'
  task :sync_source, [:source] => :environment do |_, args|
    load_tenant!
    SyncEngine.run_source!(args[:source], actor: 'rake')
    puts "#{args[:source]} sync completed"
  end

  desc 'Backfill syncRunId on mirror movements from the nearest prior sync run (idempotent)'
  task link_sync_runs: :environment do
    load_tenant!
    runs = SyncRun.unscoped.where(tenant_id: Current.tenant_id, source: 'all')
                  .order(startedAt: :asc).pluck(:id, :startedAt)
    if runs.empty?
      puts 'No sync runs to link against'
      next
    end

    linked = 0
    InventoryMovement.unscoped.where(tenant_id: Current.tenant_id, syncRunId: nil)
                     .where(source: %w[square shopify]).find_each do |movement|
      run = runs.reverse_each.find { |_, started_at| started_at <= movement.createdAt }
      next if run.nil?

      movement.update_column(:syncRunId, run[0])
      linked += 1
    end
    puts "Linked #{linked} movements to their capturing sync run"
  end

  desc 'Seed the standard chart of accounts for the active tenant (idempotent)'
  task chart_of_accounts: :environment do
    load_tenant!
    count = Finance::ChartOfAccounts.seed!
    puts "Chart of accounts seeded (#{count} accounts)"
  end

  desc 'Print catalog link stats: linked / matched / mismatched / one-sided SKUs'
  task catalog_links: :environment do
    load_tenant!
    puts CatalogLinks.summary.to_json
  end

  desc 'Dry-run: print the plan for SKUs shared across products (no changes made)'
  task sku_remediation_plan: :environment do
    load_tenant!
    plans = SkuRemediationPlanner.plan
    if plans.empty?
      puts 'No shared SKUs found — nothing to plan.'
      next
    end

    puts 'Shared SKUs -> proposed unique SKUs (apply requires updating Shopify + Square + re-linking):'
    plans.group_by(&:sku).each do |sku, group|
      puts "\n#{sku} (#{group.length} variants):"
      group.each do |plan|
        puts "  #{plan.product.ljust(48)} #{plan.variant_title.ljust(18)} qty=#{plan.current_qty}  ->  #{plan.proposed_sku}"
      end
    end
  end

  desc 'Seed size families from products labeled the same (group by product title, members derived from Square variation names). Idempotent, approval mode.'
  task seed_families: :environment do
    load_tenant!

    square_totals = InventoryLevel.where(source: 'square').group(:squareVariationId).sum(:quantity)

    # Candidate memberships: tracked Shopify variants with a SKU, grouped by
    # product title. Grams come from the Square variation name (physical truth),
    # falling back to a numeric prefix in the SKU.
    candidates = ShopifyVariant.where(tracked: true).where.not(sku: [nil, '']).includes(:product)
                               .to_a.group_by { |v| v.product&.title }.filter_map do |title, variants|
      members = variants.filter_map do |v|
        link = SkuLink.find_by(shopifyVariantId: v.id) || SkuLink.find_by(sku: v.sku)
        variation = link ? SquareVariation.find_by(id: link.squareVariationId) : SquareVariation.find_by(sku: v.sku)
        grams = variation&.name.to_s.match(/\d+(\.\d+)?/)&.[](0)&.to_f
        grams ||= v.sku.to_s.match(/\d+(\.\d+)?/)&.[](0)&.to_f
        next if grams.nil? || grams <= 0

        { sku: v.sku.to_s, grams: grams, square_variation_id: variation&.id, variant_id: v.id }
      end
      next if title.blank? || members.length < 2

      [title, members]
    end

    # Guard: a Square variation shared across two product labels (e.g. the rosin
    # strains share DSLR1/DSLR5 on Square) would make families fight over one
    # variation — skip every family that touches a shared variation.
    variation_use = Hash.new(0)
    candidates.each do |_, members|
      members.each do |m|
        variation_use[m[:square_variation_id]] += 1 if m[:square_variation_id]
      end
    end
    created = 0
    skipped_shared = 0

    candidates.each do |title, members|
      if members.any? { |m| m[:square_variation_id] && variation_use[m[:square_variation_id]] > 1 }
        skipped_shared += 1
        puts "SKIP #{title} — members share a Square variation used by another product"
        next
      end

      family = SizeFamily.find_or_create_by!(name: title, tenant_id: Current.tenant_id)
      family.previous_changes['id'].present? || family.created_at_previously_changed?
      family.update!(mode: 'approval')
      members.each do |m|
        member = family.members.find_or_initialize_by(sku: m[:sku])
        member.tenant_id = Current.tenant_id
        member.grams = m[:grams]
        member.square_variation_id = m[:square_variation_id]
        member.save!
      end

      base = members.sum { |m| square_totals.fetch(m[:square_variation_id], 0).to_i * m[:grams] }
      family.update!(base_grams: base, sales_watermark: Time.current) if family.base_grams.nil?
      created += 1
      puts "SEED #{title} base_grams=#{family.base_grams} members=#{members.map do |m|
        "#{m[:sku]}=#{m[:grams]}g"
      end.join(', ')}"
    end

    puts "families seeded: #{created}, skipped (shared variations): #{skipped_shared}"
  end

  namespace :audit do
    desc 'Deep audit of Square SKUs vs the live API, mirror, and Shopify links (read-only)'
    task square_skus: :environment do
      load_tenant!
      r = SquareSkuAudit.run!
      s = r.summary

      puts '=' * 70
      puts "SQUARE SKU AUDIT — #{Current.tenant.name} @ #{Time.current}"
      puts 'Run via live Square API (2 locations). Read-only; no changes made.'
      puts '=' * 70
      puts format('%-48s %6s', 'Live Square variations', s[:live_variations])
      puts format('%-48s %6s', '  with a SKU', s[:with_sku])
      puts format('%-48s %6s', '  WITHOUT a SKU', s[:without_sku])
      puts format('%-48s %6s', 'Mirrored in DB', s[:mirrored])
      puts format('%-48s %6s', '  live but NOT mirrored (missing)', s[:not_mirrored])
      puts format('%-48s %6s', '  stale mirror rows (deleted on Square)', s[:stale_mirror])
      puts format('%-48s %6s', 'Duplicate SKUs (shared)', s[:duplicate_skus])
      puts format('%-48s %6s', 'Unlinked Square variations', s[:unlinked])
      puts format('%-48s %6s', '  ..of which SELLABLE (qty>0)', s[:sellable_unlinked])
      puts format('%-48s %6s', '  ..of which sellable AND no SKU', s[:sellable_no_sku])
      puts format('%-48s %6s', 'Shopify variants w/o Square SKU (excl ROUTEINS)', s[:real_unmatched])
      puts format('%-48s %6s', 'Variations with zero/absent inventory', s[:zero_qty])

      unless r.stale_mirror.empty?
        puts "\nStale mirror rows (no longer in live API):"
        r.stale_mirror.each do |v|
          puts "  #{v.id}  #{v.name}  sku=#{v.sku.presence || '(none)'}  syncedAt=#{v.syncedAt}"
        end
      end
      unless r.sellable_unlinked.empty?
        puts "\nSellable (qty>0) but UNLINKED (top 25 by qty):"
        r.sellable_unlinked.sort_by { |v| -r.counts[v[:variationId]].to_i }.first(25).each do |v|
          puts format('  %5d  %-30s  sku=%-14s', r.counts[v[:variationId]].to_i, v[:name][0, 30],
            v[:sku].presence || '(none)')
        end
      end
      unless r.sellable_no_sku.empty?
        puts "\nSellable AND no SKU (cannot auto-link):"
        r.sellable_no_sku.sort_by { |v| -r.counts[v[:variationId]].to_i }.each do |v|
          puts format('  %5d  %-30s', r.counts[v[:variationId]].to_i, v[:name][0, 30])
        end
      end
      unless r.real_unmatched.empty?
        puts "\nShopify variants with no Square SKU match (excl ROUTEINS):"
        r.real_unmatched.each do |v|
          puts "  #{v.title}  sku=#{v.sku}  tracked=#{v.tracked}  product=#{v.product&.title}"
        end
      end
    end

    desc 'Delete stale SquareVariation mirror rows that no longer exist in the live API (DB-only; deletes rows — requires TENANT_ID)'
    task prune_stale_mirror: :environment do
      load_tenant!(write: true)
      live_ids = SquareClient.catalog.map { |v| v[:variationId] }.to_set
      stale = SquareVariation.where(tenant_id: Current.tenant_id).reject { |v| live_ids.include?(v.id) }
      if stale.empty?
        puts 'No stale mirror rows — mirror matches live Square catalog.'
        next
      end

      ids = stale.map(&:id)
      levels = InventoryLevel.where(squareVariationId: ids).destroy_all
      movements = InventoryMovement.where(squareVariationId: ids).destroy_all
      alerts = StockAlert.where(squareVariationId: ids).destroy_all
      links = SkuLink.where(squareVariationId: ids).destroy_all
      SquareVariation.where(id: ids).delete_all

      puts "Removed #{stale.length} stale SquareVariation rows not in live API (syncedAt <= #{stale.map(&:syncedAt).max}):"
      stale.each { |v| puts "  - #{v.id}  #{v.name}  sku=#{v.sku.presence || '(none)'}" }
      puts "Dependents removed: #{levels.size} levels, #{movements.size} movements, #{alerts.size} alerts, #{links.size} links."
    end
  end

  namespace :remediate do
    desc 'Dry-run: print the Square SKU remediation plan (links + SKU writes + dup fix). No writes.'
    task square_skus: :environment do
      load_tenant!
      plan = SquareSkuRemediator.build_plan!
      s = plan[:summary]
      puts 'SQUARE SKU REMEDIATION PLAN (DRY-RUN — nothing applied)'
      puts "Generated: #{plan[:generated_at]}  tenant=#{Current.tenant.name}"
      puts "  links to create (DB-only):       #{s[:links]}"
      puts "  Square SKU assignments (writes): #{s[:sku_assignments]}"
      puts "  duplicate SKU fixes (writes):    #{s[:duplicate_fix]}"
      puts ''

      puts "A) LINKS TO CREATE (SkuLink rows -> #{s[:links]})"
      plan[:links_to_create].first(30).each do |rec|
        puts format('  L  %-32s sku=%-14s  ->  $%-10s %s (score=%d)',
          rec[:square][:name][0, 32], rec[:square][:sku].presence || '(none)', rec[:shopify].product&.title.to_s[0, 40], rec[:shopify].title.to_s[0, 30], rec[:score])
      end
      puts "  ... and #{s[:links] - 30} more" if s[:links] > 30

      puts "\nB) SQUARE SKU ASSIGNMENTS (UpsertCatalogObject -> #{s[:sku_assignments]})"
      plan[:sku_assignments].each do |w|
        puts format('  S  %5d  %-32s item=%-28s -> SKU %s',
          w[:qty], w[:variation][:name][0, 32], w[:item_name][0, 28], w[:proposed_sku])
      end

      puts "\nC) DUPLICATE SKU FIX"
      if plan[:duplicate_fix]
        w = plan[:duplicate_fix]
        puts format('  D  %-32s (%s) -> SKU %s', w[:variation][:name], w[:variation][:variationId], w[:proposed_sku])
      else
        puts '  (none)'
      end

      puts "\nTo apply after review:  CONFIRM_REMEDIATION=yes TENANT_ID=... rails ops:remediate:square_skus:apply"
      puts '(Square writes need an approved push window first.)'
    end

    namespace :square_skus do
      desc 'APPLY the Square SKU remediation plan (WRITES to Square; requires CONFIRM_REMEDIATION=yes + TENANT_ID)'
      task apply: :environment do
        load_tenant!(write: true)
        ENV['PUSH_CONFIRM'] = 'yes' # CONFIRM_REMEDIATION is the task-level gate
        puts JSON.pretty_generate(SquareSkuRemediator.apply!)
      end
    end
  end

  namespace :consolidate do
    desc 'Dry-run: show which per-SKU variants stay canonical and which get untracked. No writes.'
    task shopify_skus: :environment do
      load_tenant!
      plan = ShopifySkuConsolidator.build_plan!
      s = plan[:summary]
      puts 'SHOPIFY SKU CONSOLIDATION PLAN (DRY-RUN — nothing applied)'
      puts "Generated: #{plan[:generated_at]}  tenant=#{Current.tenant.name}"
      puts "  pooled-SKU groups: #{s[:groups]}"
      puts "  surplus variants to untrack: #{s[:surplus_to_untrack]}"
      puts "  canonical variants kept: #{s[:canonical_kept]}"
      puts "  ROUTEINS skipped: #{plan[:skipped_routeins]}"
      puts ''
      plan[:groups].each do |g|
        puts "SKU #{g[:base].inspect} (#{g[:size]}) -> KEEP #{g[:canonical].id}"
        puts "     canonical  [#{product_label(g[:canonical])}] tracked=#{g[:canonical].tracked} linked=#{SkuLink.linked.exists?(shopifyVariantId: g[:canonical].id)}"
        g[:surplus].each do |v|
          puts "     UNTRACK    [#{product_label(v)}] tracked=#{v.tracked} linked=#{SkuLink.linked.exists?(shopifyVariantId: v.id)}"
        end
      end
      puts "\nTo apply after review: CONFIRM_CONSOLIDATE=yes TENANT_ID=... rails ops:consolidate:shopify_skus:apply"
    end

    def product_label(v)
      p = ShopifyProduct.find_by(id: v.productId)
      p ? "#{p.title.to_s[0, 38]} / #{p.status}" : '?'
    end

    namespace :shopify_skus do
      desc 'APPLY Shopify SKU consolidation (untrack surplus variants). Requires CONFIRM_CONSOLIDATE=yes + TENANT_ID'
      task apply: :environment do
        load_tenant!(write: true)
        puts JSON.pretty_generate(ShopifySkuConsolidator.apply!)
      end
    end
  end

  namespace :push_guard do
    desc 'Show push-guard status for Shopify and Square (freeze + approval windows)'
    task status: :environment do
      load_tenant!
      PlatformPushGuard.status_all.each do |st|
        state = if st[:frozen]
          'FROZEN'
        else
          (st[:window_open] ? "window OPEN until #{st[:window_expires_at]}" : 'LOCKED')
                end
        puts "#{st[:label].ljust(8)} #{state}"
        puts "  approvals: #{st[:approvals_needed]}/#{st[:approvals_required]} #{st[:approvals].map do |a|
          a[:email]
        end.join(', ').presence || '(none)'}"
        puts "  freeze reason: #{st[:freeze_reason].presence || '—'}"
        next if st[:history].empty?

        puts '  recent events:'
        st[:history].last(5).each do |h|
          puts "    #{h['at']} #{h['action']} by #{h['by']}: #{h['detail']}"
        end
      end
    end

    desc 'Record an explicit approval to open a push window: ops:push_guard:approve[square,email] (or APPROVER_EMAIL env)'
    task :approve, %i[platform email] => :environment do |_, args|
      load_tenant!
      email = args[:email] || ENV['APPROVER_EMAIL']
      raise 'Provide an approver email as the second argument or set APPROVER_EMAIL' if email.blank?

      result = PlatformPushGuard.approve!(args[:platform], email: email)
      if result[:window_open]
        puts "#{PlatformPushGuard.label(args[:platform])} push window OPEN (#{result[:approved_by]}/#{result[:needed]}) until #{result[:window_expires_at]}"
      else
        puts "Approval recorded for #{PlatformPushGuard.label(args[:platform])} — #{result[:approved_by]} of #{result[:needed]} approvals needed."
      end
    end

    desc 'Freeze all pushes to a platform (maintenance): ops:push_guard:freeze[square,reason]'
    task :freeze, %i[platform reason] => :environment do |_, args|
      load_tenant!
      PlatformPushGuard.freeze!(args[:platform], reason: args[:reason], actor: ENV['ACTOR_EMAIL'].presence || 'rake')
      puts "#{PlatformPushGuard.label(args[:platform])} FROZEN — no writes until unfrozen (syncs still run as read-only mirrors)."
    end

    desc 'Unfreeze a platform (writes still require an approved window): ops:push_guard:unfreeze[square]'
    task :unfreeze, [:platform] => :environment do |_, args|
      load_tenant!
      PlatformPushGuard.unfreeze!(args[:platform], actor: ENV['ACTOR_EMAIL'].presence || 'rake')
      puts "#{PlatformPushGuard.label(args[:platform])} unfrozen — pushes still need an approved window."
    end
  end
end

namespace :ops do
  desc 'Re-encrypt Shop rows whose Shopify token was stored before encryption was enabled (idempotent)'
  task encrypt_shop_tokens: :environment do
    rewritten = 0
    Shop.find_each do |shop|
      shop.encrypt unless shop.encrypted_attribute?(:shopify_token)
      rewritten += 1 if shop.saved_changes? || shop.previous_changes.any?
    end
    puts "Shop rows checked: #{Shop.count}; re-encrypted: #{rewritten}"
  end
end
