# frozen_string_literal: true

module Finance
  # Every entry path changes the payment and its current posting together.
  class VendorPaymentWorkflow
    def self.save!(payment, actor:)
      mutate(payment) do
        payment.save!
        Posting.vendor_payment(payment, created_by: actor)
      end
    end

    def self.discard!(payment)
      mutate(payment) do
        payment.reload
        payment.discard! unless payment.discarded?
        Posting.void_source('Finance::VendorPayment', payment.id)
      end
    end

    def self.restore!(payment, actor:)
      mutate(payment) do
        payment.reload
        payment.undiscard! if payment.discarded?
        Posting.vendor_payment(payment, created_by: actor)
      end
    end

    def self.mutate(payment)
      VendorPayment.transaction do
        Tenant.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
        raise ActiveRecord::RecordNotFound unless payment.tenant_id.blank? || payment.tenant_id == Current.tenant_id

        yield
        payment
      end
    end
    private_class_method :mutate
  end
end
