# frozen_string_literal: true

require 'digest'
require 'json'
require 'uri'

module Ctrax
  # Complete native read, then atomic local publication. No source/payroll writes.
  class LaborImport
    class Error < StandardError
      attr_reader :reason

      def initialize(message, reason: :response)
        @reason = reason
        super(message)
      end
    end
    UNASSIGNED_ISSUE = 'Source store not supplied; unassigned evidence, excluded from payroll.'
    FIELDS = %w[id store_id user_id started_at ended_at number_of_hours is_in_progress is_verified deleted_at
                updated_at explicitly_verified_at explicitly_verified_by_id].freeze

    def self.call(actor: Current.user, sync_configuration: nil)
      new(actor: actor, sync_configuration: sync_configuration).call
    end

    def initialize(actor: Current.user, sync_configuration: nil)
      @actor_id = actor&.id
      @sync_configuration = sync_configuration
    end

    def call
      authorize!
      @started = Time.current
      @connection = PosConnection.find_by(provider: 'ctrax', vendor_approved: true)
      raise Error, 'Configure approved C-Trax read access first.' unless @connection&.credentials_saved?

      credentials = @connection.credential_values
      @fingerprint = Digest::SHA256.hexdigest([@connection.id, credentials].to_json)
      @origin = credentials.fetch('api_url')
      @publication_key = 'ctrax_labor_publication:' + Digest::SHA256.hexdigest(@origin)
      @publication_token = Setting.find_by(tenant_id: Current.tenant_id, key: @publication_key)&.value
      client = Client.new(credentials)
      stores = client.stores.map { |store| store.fetch(:id).to_s }
      rows = [false, true].flat_map do |in_progress|
        client.labor_shifts(in_progress: in_progress).map do |row|
          validate_shape!(row, stores, in_progress)
          row
        end
      end
      ids = rows.map { |row| row.fetch('id').to_s }
      raise Error, 'Duplicate C-Trax labor identities; previous history retained.' unless ids.uniq.length == ids.length

      CtraxLaborShift.transaction do
        raise Error, 'Workspace unavailable.' unless Tenant.where(id: Current.tenant_id,
          status: 'active').update_all('updated_at = updated_at') == 1

        authorize!
        CtraxLaborSync.verify!(@sync_configuration) if @sync_configuration
        if Setting.find_by(tenant_id: Current.tenant_id, key: @publication_key)&.value != @publication_token
          raise Error.new('A newer complete C-Trax read was already published; retry the read.', reason: :changed)
        end
        unless @fingerprint == credentials_fingerprint
          raise Error,
            'C-Trax credentials changed; previous history retained.'
        end
        if CtraxLaborShift.where(source_origin: @origin).where('last_seen_at > ?', @started).exists?
          raise Error, 'A newer C-Trax read was published; retry the read.'
        end

        plan = build_plan(rows)
        flag_overlaps(plan)
        plan.each { |item| publish(item) }
        CtraxLaborShift.where(source_origin: @origin).where.not(external_id: ids).find_each do |record|
          status = record.store_id.nil? ? 'unassigned' : 'missing'
          issue = 'Not returned by the complete C-Trax read; original history retained.'
          issue = UNASSIGNED_ISSUE + ' ' + issue if record.store_id.nil?
          record.update!(status: status, issue: issue)
          append_observation(record)
        end
        Setting.find_or_create_for(@publication_key, Current.tenant_id) { |setting| setting.value = SecureRandom.hex(24) }
        statuses = CtraxLaborShift.where(source_origin: @origin).group(:status).count
        { stores: stores.length, shifts: rows.length, imported: statuses.fetch('imported', 0), open: statuses.fetch('open', 0),
          unmatched: statuses.fetch('unmatched', 0), issues: statuses.except('imported').values.sum,
          changed: statuses.fetch('changed', 0), missing: statuses.fetch('missing', 0), statuses: statuses }
      end
    rescue Client::Error => error
      raise Error.new('C-Trax labor read failed or was incomplete; previous history retained.', reason: error.reason)
    rescue KeyError, TypeError, JSON::ParserError
      raise Error, 'C-Trax labor read failed or was incomplete; previous history retained.'
    end

    private

    def authorize!
      actor = User.find_by(id: @actor_id, active: true)
      raise Pundit::NotAuthorizedError unless actor&.can_manage_accounts? && actor.can?('timesheets.write') &&
                                              Tenant.exists?(id: Current.tenant_id,
                                                status: 'active') && (actor.super_admin? || actor.tenant_id == Current.tenant_id)
    end

    def credentials_fingerprint
      connection = PosConnection.find_by(id: @connection.id, provider: 'ctrax', vendor_approved: true)
      raise Error, 'C-Trax read access changed; previous history retained.' unless connection&.credentials_saved?

      Digest::SHA256.hexdigest([connection.id, connection.credential_values].to_json)
    end

    def validate_shape!(row, stores, in_progress)
      valid_id = ->(value) { value.is_a?(Integer) && value.positive? && value.to_s.length <= 19 }
      native_identity = row.is_a?(Hash) && %w[id user_id].all? { |key| valid_id.call(row[key]) } &&
        (row['store_id'].nil? || valid_id.call(row['store_id']))
      raise Error, 'Invalid C-Trax labor identity; previous history retained.' unless native_identity

      permitted = stores.include?(row['store_id'].to_s)
      if row['store_id'].nil?
        identity = EmployeeSourceIdentity.includes(:employee).find_by(source: 'ctrax',
          external_id: "#{URI(@origin).host}/#{row['user_id']}")
        permitted = identity&.employee&.tenant_id == Current.tenant_id
      end
      state_matches = row['is_in_progress'] == in_progress && [true, false].include?(row['is_verified'])
      user_matches = row['user'].nil? || (row['user'].is_a?(Hash) && row.dig('user', 'id') == row['user_id'])
      timestamps_valid = %w[started_at ended_at deleted_at updated_at explicitly_verified_at].all? do |key|
        row[key].nil? || (row[key].is_a?(String) && row[key].valid_encoding? && row[key].bytesize <= 100)
      end
      unless permitted && state_matches && user_matches && timestamps_valid
        raise Error, 'Unexpected C-Trax labor schema or store scope; previous history retained.'
      end
    end

    def normalized_payload(row)
      selected = row.slice(*FIELDS)
      hours = selected['number_of_hours']
      selected['number_of_hours'] = nil unless hours.is_a?(Numeric) && hours.finite?
      reviewer = selected['explicitly_verified_by_id']
      selected['explicitly_verified_by_id'] = nil if reviewer && !reviewer.is_a?(Integer)
      JSON.generate(selected.sort.to_h)
    end

    def build_plan(rows)
      identities = EmployeeSourceIdentity.where(source: 'ctrax').includes(:employee).index_by(&:external_id)
      existing = CtraxLaborShift.where(source_origin: @origin).index_by(&:external_id)
      host = URI(@origin).host
      rows.map do |row|
        payload = normalized_payload(row)
        digest = Digest::SHA256.hexdigest(payload)
        employee = identities["#{host}/#{row['user_id']}"]&.employee
        item = normalize(row).merge(id: row['id'].to_s, employee: employee, payload: payload, digest: digest,
          old: existing[row['id'].to_s], row: row)
        if item[:old] && (item[:old].original_digest != digest || (item[:old].employee_id && item[:old].employee_id != employee&.id))
          item.merge!(status: 'changed',
            issue: 'Source or worker mapping changed; original history retained for review.')
        elsif !employee
          item.merge!(status: 'unmatched', issue: 'No consolidated employee matches this native C-Trax user.')
        end
        if row['store_id'].nil? && employee&.tenant_id != Current.tenant_id
          raise Error, 'Unassigned C-Trax evidence no longer has an exact workspace employee mapping.'
        end
        if (item[:old] && item[:old].store_id.nil?) || (!item[:old] && row['store_id'].nil?)
          changed = item[:status] == 'changed'
          item.merge!(status: 'unassigned', issue: UNASSIGNED_ISSUE + (changed ? ' Latest source observation changed; original retained.' : ''))
        end
        item
      end
    end

    def timestamp(value)
      raise ArgumentError unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d\d:\d\d)\z/)

      Time.iso8601(value)
    end

    def normalize(row)
      start_at = timestamp(row['started_at'])
      end_at = timestamp(row['ended_at']) if row['ended_at']
      updated = timestamp(row['updated_at']) if row['updated_at']
      value = row['number_of_hours']
      reported = BigDecimal(value.to_s) if value.is_a?(Numeric) && value.finite? && value >= 0 && value <= 100_000
      elapsed = end_at && BigDecimal((end_at - start_at).to_s) / 3600
      status, issue = source_status(row, start_at, end_at, reported, elapsed)
      { status: status, issue: issue, attributes: {
        started_at: start_at, ended_at: end_at, source_updated_at: updated, reported_hours: reported,
        elapsed_hours: elapsed, in_progress: row['is_in_progress'], verified: row['is_verified']
      } }
    rescue ArgumentError, TypeError
      { status: 'invalid', issue: 'Unverifiable source timestamps; original observation retained.', attributes: {
        reported_hours: nil, in_progress: row['is_in_progress'], verified: row['is_verified']
      } }
    end

    def source_status(row, start_at, end_at, reported, elapsed)
      if row['deleted_at']
        ['deleted', 'Source marks this shift deleted; retained as historical evidence.']
      elsif start_at > Time.current || (end_at && (end_at < start_at || end_at > Time.current)) ||
            (!row['is_in_progress'] && !end_at) || (row['is_in_progress'] && end_at)
        ['invalid', 'Inconsistent source clock boundaries; review the source record.']
      elsif row['is_in_progress']
        ['open', 'Open source shift; no payable hours are generated.']
      elsif reported.nil?
        ['invalid', 'Source reported hours are unknown or invalid; no hours inferred.']
      elsif (reported - elapsed).abs > BigDecimal('0.01')
        ['conflict', 'Reported hours differ from elapsed time; breaks or adjustments are unverified.']
      else
        ['imported', nil]
      end
    end

    def flag_overlaps(plan)
      plan.each do |item|
        next unless item[:employee] && item[:status] == 'imported'

        first = item[:attributes][:started_at]
        last = item[:attributes][:ended_at]
        employee_id = item[:employee].id
        source_overlap = plan.any? do |other|
          other != item && other[:employee]&.id == employee_id && other[:attributes][:started_at] &&
            other[:attributes][:started_at] < last && (!other[:attributes][:ended_at] || other[:attributes][:ended_at] > first)
        end
        clocks = ClockShift.where(employee_id: employee_id).where('started_at < ?', last).where(
          'ended_at IS NULL OR ended_at > ?', first
        ).exists?
        square = SquareTimecard.where(employee_id: employee_id).where('started_at < ?', last).where(
          'ended_at IS NULL OR ended_at > ?', first
        ).exists?
        local = People::TimesheetEntry.joins(:timesheet).where(timesheets: { employee_id: employee_id })
                                      .where(worked_on: first.in_time_zone.to_date..last.in_time_zone.to_date).exists?
        if source_overlap || clocks || square || local
          item.merge!(status: 'conflict',
            issue: 'Overlaps other recorded time; retained separately and excluded from payroll.')
        end
      end
    end

    def publish(item)
      record = item[:old] || CtraxLaborShift.new(source_origin: @origin, external_id: item[:id])
      if record.new_record?
        record.assign_attributes(item[:attributes].merge(employee: item[:employee], store_id: item[:row]['store_id']&.to_s,
          user_external_id: item[:row]['user_id'].to_s, original_digest: item[:digest], source_payload: item[:payload]))
      elsif record.employee_id.nil? && item[:status] != 'changed'
        record.employee = item[:employee]
      end
      record.update!(status: item[:status], issue: item[:issue], latest_payload: item[:payload],
        latest_digest: item[:digest], last_seen_at: @started)
      append_observation(record)
    end

    def append_observation(record)
      payload = JSON.generate({ record: record.latest_record, status: record.status, issue: record.issue })
      digest = Digest::SHA256.hexdigest(payload)
      previous = record.observations.order(sequence: :desc).first
      return if previous&.digest == digest

      record.observations.create!(sequence: (previous&.sequence || 0) + 1, observed_at: Time.current,
        digest: digest, payload: payload)
    end
  end
end
