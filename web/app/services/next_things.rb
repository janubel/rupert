# frozen_string_literal: true

# The Next thing to do bar: what needs this person now, most urgent first, each with the page that fixes it.
# Items come from the same read-only checks Rupert's assistants use (sync health, order queues, tasks, low-stock
# alerts, the compliance check), run as this person, so everyone sees only what they may act on. Someone those
# checks do not cover (no reports access) still sees their own late and due-today tasks.
#
# Each item: key (stable while it is the same problem), title, detail, path, level ('fix' or 'watch'), area and a
# fingerprint that changes when the problem changes, so "Done" hides it until then (NextThingDismissal).
class NextThings
  CACHE_FOR = 2.minutes
  LEVELS = { 'fix' => 0, 'watch' => 1 }.freeze
  # Within a level: broken data first, then customers waiting, then people's work, then paperwork.
  AREAS = ['Sync', 'Orders', 'Tasks', 'Books', 'People', 'Records', 'Stock'].freeze
  SOURCE_NAMES = { 'swipesimple' => 'SwipeSimple', 'ctrax' => 'C-Trax', 'shopify' => 'Shopify', 'square' => 'Square',
                   'authorize_net' => 'Authorize.net', 'iris' => 'NAB IRIS', 'iris_reporting' => 'NAB IRIS' }.freeze

  def self.for(user) = new(user).items

  def initialize(user, now: Time.current)
    @user = user
    @now = now
  end

  # Open items for this person, without the ones they marked done or snoozed.
  def items
    dismissals = NextThingDismissal.where(user_id: @user.id).index_by(&:item_key)
    all.reject { |item| dismissals[item[:key]]&.hides?(item, @now) }
  end

  def all
    Rails.cache.fetch(['next_things', @user.tenant_id, @user.id], expires_in: CACHE_FOR) { build }
  end

  # Marks an item done (hidden until it changes) or snoozed (hidden for an hour). Only items this person can see.
  def dismiss!(key, kind)
    item = all.find { |candidate| candidate[:key] == key.to_s }
    return false unless item && NextThingDismissal::KINDS.include?(kind)

    until_at = if kind == 'snooze' then @now + NextThingDismissal::SNOOZE_FOR
               elsif item[:level] == 'fix' then @now + NextThingDismissal::FIX_DONE_FOR
               end
    record = NextThingDismissal.find_or_initialize_by(user_id: @user.id, item_key: item[:key])
    record.update!(kind: kind, fingerprint: item[:fingerprint], until_at: until_at)
    true
  end

  private

  def paths = Rails.application.routes.url_helpers

  def build
    token = TeamChat::Token.new(@user)
    found = token.usable? ? sync_items(token) + queue_items(token) + task_items(token) + alert_items(token) + compliance_items(token) : own_task_items
    found.uniq { |item| item[:key] }.each_with_index.sort_by do |item, index|
      area = item[:area].to_s.end_with?(' close') ? 'Books' : item[:area]
      [LEVELS.fetch(item[:level], 2), AREAS.index(area) || AREAS.size, index]
    end.map(&:first)
  end

  def run(token, name, args = {})
    tool = Mcp::Registry.find(name)
    return nil unless tool&.available_to?(token)

    tool.new(token: token).call(args).data
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { next_things: name })
    nil
  end

  def item(key:, title:, path:, level:, area:, fingerprint:, detail: nil)
    { key: key, title: title.to_s.first(140), detail: detail.to_s.first(200).presence, path: path, level: level, area: area,
      fingerprint: fingerprint.to_s }
  end

  def sync_items(token)
    Array(run(token, 'sync_health')&.dig(:channels)).select { |row| row[:failing] }.map do |row|
      name = SOURCE_NAMES.fetch(row[:source].to_s, row[:source].to_s.titleize)
      since = row[:last_success_at] ? "Last good #{Time.iso8601(row[:last_success_at]).in_time_zone.strftime('%b %-d, %-l:%M %p')}." : 'No good read yet.'
      item(key: "sync:#{row[:source]}:#{row[:operation]}", title: "#{name} #{row[:operation].to_s.tr('_', ' ')} sync is failing",
        detail: [row[:failure_category].to_s.tr('_', ' ').capitalize.presence, since].compact.join(' · '),
        path: paths.syncs_path, level: 'fix', area: 'Sync', fingerprint: row[:last_success_at] || 'never')
    end
  end

  def queue_items(token)
    Array(run(token, 'order_queues', { 'oldest' => 0 })&.dig(:queues)).select { |queue| queue[:count].to_i.positive? }.map do |queue|
      late = queue[:late].to_i
      item(key: "queue:#{queue[:name].to_s.parameterize}", title: "#{queue[:name]}: #{queue[:count]}#{" (#{late} late)" if late.positive?}",
        path: queue[:path].presence || paths.root_path, level: late.positive? ? 'fix' : 'watch', area: 'Orders',
        fingerprint: "#{queue[:count]}/#{late}")
    end
  end

  def task_items(token)
    mine = Array(run(token, 'list_tasks', { 'overdue' => true, 'assigned_to_me' => true, 'per_page' => 3 })&.dig(:rows)).map do |task|
      task_item(task[:id], task[:title], task[:due_on], 'fix', task[:status])
    end
    everyone = run(token, 'list_tasks', { 'overdue' => true, 'per_page' => 1 })
    total = everyone&.dig(:meta, :total).to_i
    others = total - mine.size
    mine << item(key: 'tasks:overdue', title: "#{others} other overdue task#{'s' unless others == 1} on the board", path: paths.projects_tasks_path,
      level: 'watch', area: 'Tasks', fingerprint: total) if others.positive?
    mine
  end

  def own_task_items
    scope = Projects::TaskPolicy::Scope.new(@user, Projects::Task).resolve.assigned_to(@user.id).unfinished
    late = scope.where('due_on < ?', Date.current).by_priority.limit(3).map { |task| task_item(task.id, task.title, task.due_on, 'fix', task.status) }
    today = scope.where(due_on: Date.current).by_priority.limit(3).map { |task| task_item(task.id, task.title, task.due_on, 'watch', task.status) }
    late + today
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { next_things: 'own_tasks' })
    []
  end

  def task_item(id, title, due_on, level, status)
    due = due_on && Date.parse(due_on.to_s)
    detail = if due.nil? then nil
             elsif due < Date.current then "Due #{due.strftime('%b %-d')}, #{(Date.current - due).to_i} day#{'s' unless (Date.current - due).to_i == 1} late"
             else 'Due today'
             end
    item(key: "task:#{id}", title: title, detail: detail, path: paths.projects_task_path(id), level: level, area: 'Tasks',
      fingerprint: "#{status}/#{due_on}")
  end

  def alert_items(token)
    counts = run(token, 'list_alerts', { 'status' => 'open', 'per_page' => 1 })&.dig(:counts) || {}
    open = (counts[:open] || counts['open']).to_i
    return [] unless open.positive?

    [item(key: 'alerts:open', title: "#{open} low-stock alert#{'s' unless open == 1} open", path: paths.alerts_path,
      level: 'watch', area: 'Stock', fingerprint: open)]
  end

  def compliance_items(token)
    Array(run(token, 'compliance_check')&.dig(:items)).select { |row| LEVELS.key?(row[:status].to_s) && row[:path].present? }.map do |row|
      title = row[:count].to_i.positive? && !row[:title].to_s.include?(row[:count].to_s) ? "#{row[:title]}: #{row[:count]}" : row[:title]
      item(key: "check:#{row[:area].to_s.parameterize}:#{row[:title].to_s.parameterize}".first(200), title: title, detail: row[:detail],
        path: row[:path], level: row[:status].to_s, area: row[:area].to_s,
        fingerprint: "#{row[:status]}/#{row[:count]}")
    end
  end
end
