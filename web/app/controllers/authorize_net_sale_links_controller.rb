# frozen_string_literal: true

class AuthorizeNetSaleLinksController < AuthenticatedController
  before_action :private_response

  def index
    authorize(:module, :payroll_read?)
    @payments = AuthorizeNetTransaction.where(environment: 'production').order(submitted_at: :desc).limit(100).to_a
    @links = AuthorizeNetSaleLink.active.where(authorize_net_transaction_id: @payments.map(&:id)).includes(:order, :authorize_net_transaction).index_by(&:authorize_net_transaction_id)
    @candidates = @payments.to_h do |payment|
      orders = payment.invoice_number.present? ? Core::Order.where('order_number = ? OR source_order_id = ?', payment.invoice_number, payment.invoice_number)
        .where(currency: payment.currency, gross_cents: ((payment.payment_status == 'settledSuccessfully' ? payment.settled_amount : payment.authorized_amount) * 100)).limit(5).to_a : []
      [payment.id, orders]
    end
  end

  def create
    authorize(:module, :payroll_write?)
    payment = AuthorizeNetTransaction.find(params[:payment_id])
    source = params[:source].to_s
    raise ArgumentError, 'Choose a supported sales source.' unless CommissionPreview::SOURCES.include?(source)
    reference = params[:order_reference].to_s.strip
    raise ArgumentError, 'Enter the exact sale number or source order ID.' if reference.blank? || reference.bytesize > 200
    orders = Core::Order.where(source: source).where('order_number = ? OR source_order_id = ?', reference, reference).limit(2).to_a
    raise ArgumentError, 'The reference must identify exactly one sale in this source.' unless orders.one?

    AuthorizeNetSaleLink.transaction do
      Tenant.where(id: Current.tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
      link = AuthorizeNetSaleLink.create!(authorize_net_transaction: payment, order: orders.first,
        reviewed_by: Current.user, evidence_note: params[:evidence_note].to_s)
      ActivityLogger.log('authorize_net_sale_matched', subject: link, details: "Payment observation #{payment.id}; sale #{orders.first.id}")
    end
    redirect_to authorize_net_sale_links_path, notice: 'Payment matched to the existing sale. Its current gateway status now controls commission eligibility.'
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    message = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message
    redirect_to authorize_net_sale_links_path, alert: message
  rescue ActiveRecord::RecordNotUnique
    redirect_to authorize_net_sale_links_path, alert: 'This sale or payment already has an active match. Review and revoke an incorrect match first.'
  end

  def revoke
    authorize(:module, :payroll_write?)
    link = AuthorizeNetSaleLink.active.find(params[:id])
    link.with_lock do
      link.update!(revoked_at: Time.current, revoked_by: Current.user)
      ActivityLogger.log('authorize_net_sale_match_revoked', subject: link, details: 'Previous match retained for audit')
    end
    redirect_to authorize_net_sale_links_path, notice: 'Match revoked and retained in the audit history. Review the sale before creating a replacement.'
  end

  private

  def private_response
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end
end
