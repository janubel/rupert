# frozen_string_literal: true

module OpsLog
  # What a controller knows at the end of an action that the request line cannot:
  # who was acting, which form failed validation (model, field names, error kinds,
  # never values), whether access was denied, and fingerprints of uploaded files.
  # Called from ApplicationController#append_info_to_payload; never raises.
  module ControllerContext
    PERMISSION_PHRASES = /permission|not allowed|not authorized|only the (super )?admin|access denied/i
    MAX_HASH_BYTES = 50.megabytes
    MAX_UPLOADS = 5

    class << self
      def capture(controller)
        status = controller.response.status
        info = OpsLog.actor_fields
        info[:validation] = validation_failures(controller) if validation_candidate?(controller, status)
        info[:denied] = denial(controller, status)
        info[:uploads] = uploads(controller.request) unless controller.request.get? || controller.request.head?
        info.compact
      rescue StandardError
        {}
      end

      private

      def validation_candidate?(controller, status)
        status == 422 || (status == 200 && !controller.request.get? && !controller.request.head?)
      end

      # Every model the action left in an instance variable that has errors.
      def validation_failures(controller)
        controller.instance_variables.filter_map do |name|
          next if name.start_with?('@_')

          record = controller.instance_variable_get(name)
          next unless record.respond_to?(:errors) && record.respond_to?(:model_name) && record.errors.any?

          details = record.errors.map { |error| [error.attribute.to_s, error.type.is_a?(Symbol) ? error.type.to_s : 'custom'] }
          { model: record.class.name, fields: details.map(&:first).uniq.first(15), kinds: details.map(&:last).uniq.first(10), errors: details.size }
        end.first(3)
      end

      def denial(controller, status)
        denied = controller.instance_variable_get(:@ops_denied)
        return denied if denied
        return { via: 'status_403' } if status == 403

        # flash_hash is the flash only if the action already loaded it; reading controller.flash
        # would load (and re-commit) the session of requests that never touched it.
        alert = controller.request.flash_hash&.[](:alert).to_s
        { via: 'flash' } if alert.match?(PERMISSION_PHRASES)
      end

      def uploads(request)
        found = []
        collect(request.params, found, 0)
        found.first(MAX_UPLOADS).map { |param, upload| fingerprint(param, upload) }
      end

      def collect(value, found, depth)
        return if depth > 4 || found.size >= MAX_UPLOADS

        case value
        when ActionDispatch::Http::UploadedFile then found << ['file', value]
        when Hash, ActionController::Parameters
          value.each { |key, item| item.is_a?(ActionDispatch::Http::UploadedFile) ? found << [key.to_s, item] : collect(item, found, depth + 1) }
        when Array then value.each { |item| collect(item, found, depth + 1) }
        end
      end

      # Size, hash and type of a file, plus its extension. Never the name or the contents.
      def fingerprint(param, upload)
        path = upload.respond_to?(:path) ? upload.path : upload.tempfile&.path
        size = upload.size.to_i
        declared = upload.content_type.to_s.split(';').first.to_s.first(80)
        guess = path && File.open(path, 'rb') { |io| Marcel::MimeType.for(io, name: upload.original_filename.to_s) }
        { param: param.first(40), ext: File.extname(upload.original_filename.to_s).downcase.first(8), size: size,
          declared_type: declared.presence, type_guess: guess, type_matches: guess.present? && declared.present? ? guess == declared : nil,
          sha256: (path && size <= MAX_HASH_BYTES ? Digest::SHA256.file(path).hexdigest : nil) }.compact
      end
    end
  end
end
