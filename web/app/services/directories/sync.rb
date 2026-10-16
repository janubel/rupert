# frozen_string_literal: true

require 'digest'

module Directories
  # Read complete native directories, validate them, then publish atomically.
  # Native identities are kept separate; contact details never imply identity.
  class Sync
    class Error < StandardError
      def initialize
        super('Directory read failed or was incomplete. Previous records were retained; check source access and retry.')
      end
    end

    class Busy < StandardError; end
    PAIRS = { 'ctrax' => %w[customers employees], 'shopify' => %w[customers] }.freeze

    def self.available?(provider)
      return false unless Current.tenant&.status == 'active'
      case provider
      when 'ctrax'
        connection = PosConnection.find_by(provider: 'ctrax')
        connection&.vendor_approved && connection.credentials_saved?
      when 'shopify'
        %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET SHOPIFY_SHOP_DOMAIN].all? { |key| EnvStore.fetch(key, '').present? }
      else false
      end
    end

    def self.call(provider:, kind:)
      new(provider, kind).call
    end

    def initialize(provider, kind)
      @provider, @kind = provider, kind
      raise Error unless PAIRS.fetch(provider, []).include?(kind) && self.class.available?(provider)
    end

    def call
      state = DirectorySyncState.find_or_create_by!(provider: @provider, kind: @kind)
      token = SecureRandom.hex(24)
      started = Time.current
      state.with_lock do
        raise Busy, 'This directory is already syncing.' if state.status == 'running' && state.started_at && state.started_at > 15.minutes.ago

        state.update!(status: 'running', attempt_token: token, started_at: started, finished_at: nil, error: nil)
      end
      fingerprint = credentials_fingerprint
      rows = fetch_rows
      records = rows.map { |row| normalize(row) }
      raise Error unless records.map { |row| row[:external_id] }.uniq.size == records.size

      state.with_lock do
        raise Error unless state.attempt_token == token && Tenant.exists?(id: Current.tenant_id, status: 'active') && fingerprint == credentials_fingerprint && self.class.available?(@provider)

        records.each do |attributes|
          model = @kind == 'customers' ? Core::Customer : People::Employee
          record = model.find_or_initialize_by(source: @provider, external_id: attributes.fetch(:external_id))
          record.employment_type = 'unspecified' if @kind == 'employees' && record.new_record?
          record.assign_attributes(attributes.merge(source_synced_at: started))
          record.save!
        end
        # Absence from a source roster is not an HR termination or a deletion.
        if @kind == 'employees'
          People::Employee.where(source: @provider).where.not(external_id: records.map { |row| row[:external_id] })
            .update_all(source_active: false)
        end
        state.update!(status: 'success', record_count: records.size, finished_at: Time.current,
          last_success_at: started, error: nil)
      end
      records.size
    rescue Busy
      raise
    rescue StandardError
      if state && token
        DirectorySyncState.where(id: state.id, attempt_token: token).update_all(status: 'failed',
          finished_at: Time.current, error: Error.new.message, updated_at: Time.current)
      end
      raise Error
    end

    private

    def credentials_fingerprint
      EnvStore.clear_cache!
      values = if @provider == 'ctrax'
        connection = PosConnection.find_by!(provider: 'ctrax')
        [connection.id, connection.vendor_approved, connection.credential_values]
      else
        %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET SHOPIFY_SHOP_DOMAIN].map { |key| EnvStore.fetch(key, '') }
      end
      Digest::SHA256.hexdigest(values.to_json)
    end

    def fetch_rows
      return ShopifyCustomers.fetch if @provider == 'shopify'

      @credentials = PosConnection.find_by!(provider: 'ctrax').credential_values
      client = Ctrax::Client.new(@credentials)
      return client.customers if @kind == 'customers'

      client.stores.flat_map { |store| client.employees(store[:id]) }
        .reject { |row| row['is_superuser'] == true } # C-Trax platform/support accounts are not store employees.
        .group_by { |row| row.fetch('id').to_s }.values.map do |copies|
          raise Error unless copies.map { |row| row.slice('first_name', 'last_name', 'email', 'deleted_at') }.uniq.one?

          copies.first
        end
    end

    def normalize(row)
      raise Error unless row.is_a?(Hash)

      if @provider == 'shopify'
        { external_id: text(row.fetch('id'), 255), first_name: text(row['firstName']), last_name: text(row['lastName']),
          email: text(row.dig('defaultEmailAddress', 'emailAddress')), phone: text(row.dig('defaultPhoneNumber', 'phoneNumber')) }
      else
        id = row.fetch('id').to_s
        raise Error unless id.match?(/\A[1-9][0-9]{0,18}\z/)

        attributes = { external_id: "#{URI(@credentials.fetch('api_url')).host}/#{id}",
          first_name: text(row['first_name']), last_name: text(row['last_name']),
          email: text(row['email']), phone: text(row['phone_number']) }
        if @kind == 'employees'
          raise Error if attributes[:first_name].blank? || attributes[:last_name].blank?

          attributes.delete(:phone) unless row.key?('phone_number')
          attributes[:source_active] = row['deleted_at'].nil?
        end
        attributes
      end
    rescue KeyError, TypeError, NoMethodError
      raise Error
    end

    def text(value, maximum = 1000)
      return nil if value.nil?
      raise Error unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= maximum && !value.include?("\u0000")

      value.strip.presence
    end
  end
end
