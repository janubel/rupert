# frozen_string_literal: true

# A short, role-aware "first week" list. Items detect their own completion
# from real workspace state where that is possible (a saved connection, a
# successful source read, a finished lesson) and otherwise let the person
# mark them done. It only reads; nothing here changes operational records.
class GettingStartedChecklist
  Item = Struct.new(:key, :title, :hint, :path, :done, :manual, keyword_init: true) do
    def done?
      done
    end
  end

  ITEM_KEYS = %w[choose_path tour first_lesson finish_path connect_source first_read invite_team check_day customize_dashboard
                 clock_in open_pos review_queue].freeze

  attr_reader :user, :journey

  def initialize(user, journey: LearningJourney.new(user))
    @user = user
    @journey = journey
  end

  def items
    @items ||= build.compact
  end

  def done_count
    items.count(&:done?)
  end

  def total
    items.size
  end

  def percent
    total.zero? ? 0 : (done_count * 100.0 / total).round
  end

  def complete?
    total.positive? && done_count == total
  end

  def next_item
    items.find { |item| !item.done? }
  end

  private

  def manual?(key)
    journey.checklist_done.include?(key)
  end

  def build
    list = []
    list << Item.new(key: 'choose_path', title: 'Choose your learning path', hint: 'Tell Rupert what you do so the lessons fit.',
      path: '/learning#your-path', done: journey.focus_chosen? || manual?('choose_path'), manual: false)
    tour_key = user.employee? ? 'employee_home' : 'dashboard'
    list << Item.new(key: 'tour', title: user.employee? ? 'Take the staff home tour' : 'Take the dashboard tour',
      hint: 'One minute. See where numbers come from and where help lives.',
      path: user.employee? ? '/employee' : '/', done: journey.tour_done?(tour_key) || manual?('tour'), manual: false)
    list << Item.new(key: 'first_lesson', title: 'Finish your first lesson', hint: 'Steps, a worked example and a quick check.',
      path: journey.next_lesson ? "/learning/#{journey.next_lesson[:key]}" : '/learning', done: journey.completed.any?, manual: false)

    if user.employee?
      list << Item.new(key: 'clock_in', title: 'Clock in for a shift', hint: 'Your elapsed time shows on your staff home.',
        path: '/employee', done: clocked_in? || manual?('clock_in'), manual: true)
      list << Item.new(key: 'open_pos', title: 'Open the register', hint: 'Check the store and stock read before your first sale.',
        path: '/ctrax_pos', done: manual?('open_pos'), manual: true) if user.can_use_pos?
    else
      if user.can?('settings.write')
        list << Item.new(key: 'connect_source', title: 'Connect a source', hint: 'Save Shopify, Square or C-Trax details. Saving does not start a sync.',
          path: '/connections', done: source_connected? || manual?('connect_source'), manual: false)
      end
      if user.can?('sync.read')
        list << Item.new(key: 'first_read', title: 'Verify a successful source read', hint: 'A finished sync with no error, then a familiar record you recognise.',
          path: '/syncs', done: successful_sync? || manual?('first_read'), manual: false)
      end
      if user.can?('sales.read')
        list << Item.new(key: 'check_day', title: 'Check one day of sales against the source', hint: 'Pick a day you remember and compare a known sale.',
          path: '/sales', done: manual?('check_day'), manual: true)
      end
      if user.can_review_timesheets? || user.can_review_receipts?
        list << Item.new(key: 'review_queue', title: 'Open your review queue', hint: 'Timesheets or receipts waiting for a decision.',
          path: user.can_review_timesheets? ? '/people/timesheets' : '/receipts', done: manual?('review_queue'), manual: true)
      end
      if user.can_manage_accounts?
        list << Item.new(key: 'invite_team', title: 'Add a teammate', hint: 'Give each person their own account and role.',
          path: '/users/new', done: teammates? || manual?('invite_team'), manual: false)
      end
      if user.can?('dashboard.read')
        list << Item.new(key: 'customize_dashboard', title: 'Arrange your dashboard', hint: 'Show the widgets you use; hide the rest.',
          path: '/', done: journey.config.key?('widgets') || manual?('customize_dashboard'), manual: true)
      end
    end
    list << Item.new(key: 'finish_path', title: "Finish “#{journey.focus[:label]}”", hint: 'Every lesson in your path, at your pace.',
      path: '/learning#your-path', done: journey.path_complete?, manual: false)
    list
  end

  def source_connected?
    OnboardingController.configured? ||
      EnvStore.fetch('SQUARE_ACCESS_TOKEN', '').present? ||
      PosConnection.where(tenant_id: user.tenant_id).any?(&:credentials_saved?)
  rescue StandardError
    false
  end

  def successful_sync?
    SyncRun.where(tenant_id: user.tenant_id, status: 'success').exists?
  rescue StandardError
    false
  end

  def teammates?
    User.where(tenant_id: user.tenant_id).where.not(id: user.id).exists?
  end

  def clocked_in?
    worker = TimeClockService.worker_for(user, include_on_leave: true)
    worker.present? && ClockShift.where(employee_id: worker.id, user_id: user.id).exists?
  rescue StandardError
    false
  end
end
