# frozen_string_literal: true

module CustomersHelper
  def customer_money(totals)
    return '—' if totals.empty?

    totals.sort_by { |currency, _| currency.to_s }.map do |currency, cents|
      "#{currency.presence || 'Unknown currency'} #{number_with_precision(cents / 100.0, precision: 2, delimiter: ',')}"
    end.join(' · ')
  end

  def customer_directory_status(customer)
    return 'Added manually' if customer.source == 'manual'

    latest = @directory_states&.dig(customer.source)&.last_success_at
    latest && customer.source_synced_at == latest ? 'Verified in latest read' : 'Unverified / historical'
  end

  def directory_label(source)
    { 'ctrax' => 'C-Trax', 'shopify' => 'Shopify', 'square' => 'Square', 'swipesimple' => 'SwipeSimple' }.fetch(source, source.to_s.titleize)
  end

  STATUS_PILLS = { 'lead' => 'pill-clay', 'customer' => 'pill-fern', 'vip' => 'pill-olive', 'inactive' => 'pill-taupe' }.freeze

  def customer_status_pill(customer)
    tag.span(customer.crm_status.titleize, class: STATUS_PILLS.fetch(customer.crm_status, 'pill-taupe'))
  end

  def customer_tag_pills(customer)
    safe_join(customer.tag_list.map { |name| tag.span(name, class: 'pill-taupe') }, ' ')
  end

  def customer_initials(customer)
    customer.name.split(/\s+/).first(2).map { |word| word[0] }.join.upcase.presence || '?'
  end

  # Query params that make up the current filter set (without paging).
  def customer_filter_params
    request.query_parameters.except('page', 'utf8', 'commit')
  end

  # One removable chip per active filter, so people can see why a list is short.
  def customer_filter_chips
    params_hash = customer_filter_params
    chips = []
    term = params.dig(:q, :first_name_or_last_name_or_preferred_name_or_email_or_phone_cont)
    chips << ["Search: #{term}", params_hash.deep_merge('q' => { 'first_name_or_last_name_or_preferred_name_or_email_or_phone_cont' => '' })] if term.present?
    chips << ["Tag: #{params.dig(:q, :tags_cont)}", params_hash.deep_merge('q' => { 'tags_cont' => '' })] if params.dig(:q, :tags_cont).present?
    chips << ["Relationship: #{params[:status].titleize}", params_hash.except('status')] if Core::Customer::CRM_STATUSES.include?(params[:status])
    chips << ["Source: #{directory_label(params[:source])}", params_hash.except('source')] if Core::Customer::SOURCES.include?(params[:source])
    chips << [{ 'mine' => 'Assigned to me', 'unassigned' => 'Unassigned' }[params[:owner]], params_hash.except('owner')] if %w[mine unassigned].include?(params[:owner])
    chips << ['Follow-up due', params_hash.except('due')] if params[:due] == '1'
    chips << [{ 'verified' => 'Verified in latest read', 'historical' => 'Unverified / historical' }[params[:directory]], params_hash.except('directory')] if %w[verified historical].include?(params[:directory])
    chips
  end

  INTERACTION_LABELS = { 'note' => 'Note', 'call' => 'Call', 'email' => 'Email', 'meeting' => 'Meeting' }.freeze

  def follow_up_state(task)
    return ['Completed', 'pill-fern'] if task.completed_at
    return ['Overdue', 'pill-rose'] if task.due_on < Date.current
    return ['Due today', 'pill-clay'] if task.due_on == Date.current

    ['Upcoming', 'pill-taupe']
  end
end
