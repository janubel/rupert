# frozen_string_literal: true

namespace :team_chat do
  desc 'Check battery MCP calls and declared result fields without printing business values. BATTERY=cross|finance|default|all.'
  task battery_coverage: :environment do
    abort 'Battery coverage must run against a non-production fixture database.' if Rails.env.production?

    tenant = ENV['TENANT_ID'].present? ? Tenant.find(ENV['TENANT_ID']) : Tenant.where(status: 'active').first
    abort 'No active tenant is available.' unless tenant

    Current.tenant = tenant
    user = ENV['USER_EMAIL'].present? ? User.find_by!(email: ENV['USER_EMAIL'], tenant_id: tenant.id) :
      User.where(tenant_id: tenant.id, role: %w[admin super_admin], active: true).first
    abort 'An active administrator is required.' unless user && %w[admin super_admin].include?(user.role)
    Current.user = user

    set = ENV['BATTERY'].presence || 'default'
    sets = set == 'all' ? %w[default finance cross] : [set]
    failed = false
    sets.each do |name|
      items = TeamChat::Battery.items(TeamChat::Battery.config_for(name))
      report = TeamChat::BatteryCoverage.new(user: user, items: items).call
      path = Rails.root.join('tmp', 'battery', "coverage-#{name}.md")
      FileUtils.mkdir_p(path.dirname)
      File.write(path, report.markdown)
      puts "#{name}: #{report.questions.size} questions, #{report.errors} errors, #{report.missing} missing needs, " \
           "#{report.too_many_calls} cross questions over two calls"
      puts report.markdown
      puts "Report saved to #{path}"
      failed ||= !report.passed?
    end
    abort 'Battery coverage found tool errors or missing needs.' if failed
  end

  default_questions = [
    'How were sales yesterday?',
    'Anything low on stock I should know about?',
    'Are there any open alerts?',
    'Is sync healthy right now?',
    'Where do I approve timesheets?',
    'Make a task to recount the tea shelf tomorrow, high priority.'
  ].freeze

  desc 'Ask @rupert questions with the configured model and print answers, tools and timing. ' \
       'Nothing is kept (every run is rolled back). QUESTIONS="a|b" USER_EMAIL=... TENANT_ID=... ' \
       'Override the model with RUPERT_CHAT_PROVIDER / RUPERT_CHAT_MODEL / OLLAMA_URL.'
  task try: :environment do
    tenant = ENV['TENANT_ID'].present? ? Tenant.find(ENV['TENANT_ID']) : Tenant.where(status: 'active').first
    Current.tenant = tenant
    user = ENV['USER_EMAIL'].present? ? User.find_by!(email: ENV['USER_EMAIL'], tenant_id: tenant.id) : User.where(tenant_id: tenant.id, role: %w[admin super_admin], active: true).first
    Current.user = user
    config = TeamChat::ModelConfig.current
    questions = ENV['QUESTIONS'].present? ? ENV['QUESTIONS'].split('|').map(&:strip) : default_questions
    puts "Model: #{config.label} (engine #{config.engine}) · asking as #{user.display_name}"
    questions.each do |question|
      ActiveRecord::Base.transaction do
        room = TeamChat::Room.create!(name: "model-check-#{SecureRandom.hex(3)}", assistant_mode: 'all', created_by: user)
        message = room.messages.create!(user: user, body: question)
        reply = room.messages.create!(author_kind: 'assistant', status: 'pending', meta: { 'asked_by' => user.id, 'trigger_id' => message.id })
        TeamChat::Agent.new(reply, config: config).run
        reply.reload
        meta = reply.meta.to_h
        puts "\nQ: #{question}"
        puts "   #{meta['outcome']} in #{(meta['duration_ms'].to_i / 1000.0).round(1)}s · tools: #{Array(meta['tools']).join(', ').presence || 'none'} · " \
             "tokens #{meta['tokens_in']}/#{meta['tokens_out']}#{" · proposed: #{reply.actions_list.map { |action| action['summary'] }.join('; ')}" if reply.actions_list.any?}"
        puts reply.body.to_s.gsub(/^/, '   ')
        raise ActiveRecord::Rollback
      end
    end
  end
end

namespace :team_chat do
  desc 'Run the test battery (config/team_chat/battery.yml) on one bot in its test room (#test-<bot>): each answer timed and graded by DeepSeek. ' \
       'AGENT=qwen (or gemma, liquid, gemma-e2b, gemma-e4b-ud, rupert) BATTERY=finance USER_EMAIL=... ONLY=d1,w1 REPORT=path.md ' \
       'RUPERT_VERIFY=1 (check and fix each answer; saved as e.g. finance+verify)'
  task battery: :environment do
    tenant = ENV['TENANT_ID'].present? ? Tenant.find(ENV['TENANT_ID']) : Tenant.where(status: 'active').first
    Current.tenant = tenant
    user = ENV['USER_EMAIL'].present? ? User.find_by!(email: ENV['USER_EMAIL'], tenant_id: tenant.id) : User.where(tenant_id: tenant.id, role: %w[admin super_admin], active: true).first
    Current.user = user
    set = ENV['BATTERY'].presence || 'default'
    battery = TeamChat::Battery.new(user: user, agent: ENV.fetch('AGENT', 'qwen'), only: ENV['ONLY'].to_s.split(','),
      items: TeamChat::Battery.items(TeamChat::Battery.config_for(set)), set: set)
    if (done = battery.already_done) && ENV['FORCE'].blank?
      puts "Already tested: #{done.label} on the #{done.set_name} questions with this Rupert build (#{done.revision}), " \
           "#{done.started_at&.strftime('%Y-%m-%d %H:%M')}: average #{done.avg_grade}/5. See Model scores. Run with FORCE=1 to test again."
      next
    end
    battery.run
    report = battery.report_markdown
    path = ENV['REPORT'].presence || Rails.root.join('tmp', 'battery', "#{battery.run_id}-#{set}-#{battery.handle}.md").to_s
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, report)
    puts "\n#{report}\n\nReport saved to #{path}"
  end
end

namespace :team_chat do
  desc 'Save test-battery runs found in #liquid-testing (from before runs were saved) so Model scores shows them.'
  task battery_backfill: :environment do
    Tenant.where(status: 'active').find_each do |tenant|
      Current.tenant = tenant
      puts "#{tenant.name}: #{TeamChat::BatteryRun.backfill!} runs saved"
      admin = User.where(tenant_id: tenant.id, role: %w[admin super_admin], active: true).first
      puts "  test rooms: #{TeamChat::Battery.ensure_rooms!(admin).map { |room| "##{room.slug}" }.join(' ')}" if admin
    end
  end
end
