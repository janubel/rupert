# frozen_string_literal: true

class ReceiptWorkflow
  class Error < StandardError; end
  FIELDS = %i[payee incurred_on amount category notes].freeze

  def initialize(user: Current.user)
    @user = user
  end

  def create(attributes, upload)
    authorize_actor!
    raise Error, 'Choose a PDF, JPEG, PNG or WebP receipt, up to 10 MB.' unless upload.respond_to?(:read)

    bytes = upload.read(PurchaseReceipt::MAX_BYTES + 1).to_s.b
    raise Error, 'Receipt must contain a file of up to 10 MB.' unless bytes.bytesize.between?(1, PurchaseReceipt::MAX_BYTES)

    type, extension = file_type(bytes)
    raise Error, 'Only PDF, JPEG, PNG and WebP receipts are accepted.' unless type

    receipt = PurchaseReceipt.new(attributes.symbolize_keys.slice(*FIELDS))
    receipt.assign_attributes(submitted_by: @user, tenant_id: Current.tenant_id, filename: "receipt.#{extension}",
      content_type: type, byte_size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes), content_base64: Base64.strict_encode64(bytes))
    PurchaseReceipt.transaction do
      receipt.save!
      record_event(receipt, 'uploaded')
    end
    receipt
  rescue ActiveRecord::RecordNotUnique
    raise Error, 'This file was already uploaded by you. Open the existing receipt.'
  end

  def change(receipt, action, attributes: {}, version:, note: nil, confirmed: nil)
    authorize_actor!
    PurchaseReceipt.transaction do
      # Acquire the workspace write lock first on SQLite.
      Tenant.unscoped.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
      receipt.reload
      raise Error, 'This receipt changed. Refresh and review it again.' unless version.to_s == receipt.lock_version.to_s
      raise Error, 'Receipt is outside this workspace.' unless receipt.tenant_id == Current.tenant_id

      owner = receipt.submitted_by_id == @user.id
      case action.to_s
      when 'update'
        raise Error, 'Only your own draft can be edited.' unless owner && receipt.status == 'draft'

        receipt.assign_attributes(attributes.symbolize_keys.slice(*FIELDS))
      when 'submit'
        raise Error, 'Only your own draft can be submitted.' unless owner && receipt.status == 'draft'

        receipt.status = 'submitted'
      when 'approve', 'reject'
        raise Error, 'Receipt review permission is required.' unless @user.can_review_receipts?
        raise Error, 'You cannot review your own receipt.' if owner
        raise Error, 'Only submitted receipts can be reviewed.' unless receipt.status == 'submitted'
        raise Error, 'Confirm you reviewed the receipt and purchase details.' unless confirmed == '1'
        raise Error, 'Explain the correction needed.' if action.to_s == 'reject' && note.to_s.strip.blank?

        receipt.status = action.to_s == 'approve' ? 'approved' : 'rejected'
      when 'reopen'
        raise Error, 'Only your own returned receipt can be reopened.' unless owner && receipt.status == 'rejected'

        receipt.status = 'draft'
      else
        raise Error, 'Unknown receipt action.'
      end
      # Repeated no-op saves must still advance the review version.
      receipt.updated_at = Time.current
      receipt.save!
      record_event(receipt, action.to_s, note: note)
    end
    receipt
  end

  private

  def authorize_actor!
    raise Error, 'Sign in to an active workspace.' unless @user&.active? && Current.tenant_id.present?
    raise Error, 'Receipt access is unavailable.' unless @user.super_admin? || @user.tenant_id == Current.tenant_id
  end

  def record_event(receipt, action, note: nil)
    receipt.events.create!(tenant_id: receipt.tenant_id, actor: @user, action: action, note: note.to_s.strip.presence,
      snapshot_json: receipt.attributes.slice('payee', 'incurred_on', 'amount_cents', 'currency', 'category', 'notes', 'sha256', 'status', 'lock_version').to_json)
    ActivityLogger.log("receipt_#{action}", subject: receipt)
  end

  def file_type(bytes)
    return ['application/pdf', 'pdf'] if bytes.start_with?('%PDF-')
    return ['image/jpeg', 'jpg'] if bytes.start_with?("\xFF\xD8\xFF".b)
    return ['image/png', 'png'] if bytes.start_with?("\x89PNG\r\n\x1A\n".b)
    return ['image/webp', 'webp'] if bytes.start_with?('RIFF') && bytes.byteslice(8, 4) == 'WEBP'

    nil
  end
end
