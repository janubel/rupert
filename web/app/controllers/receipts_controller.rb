# frozen_string_literal: true

class ReceiptsController < AuthenticatedController
  before_action :prevent_caching
  before_action :set_receipt, except: %i[index new create]
  rescue_from ReceiptWorkflow::Error, ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError, with: :workflow_error

  def index
    @reviewer = Current.user.can_review_receipts?
    @status = params[:status].presence || (@reviewer ? 'submitted' : 'all')
    @status = 'all' unless (PurchaseReceipt::STATUSES + ['all']).include?(@status)
    visible = PurchaseReceipt.visible_to(Current.user)
    @awaiting = visible.where(status: 'submitted').count
    scope = @status == 'all' ? visible : visible.where(status: @status)
    # Keep encrypted file bodies out of list queries.
    scope = scope.select(PurchaseReceipt.column_names.excluding('content_base64'))
    @pagy, @receipts = pagy(scope.includes(:submitted_by).order(created_at: :desc, id: :desc), items: 30)
  end

  def new
    @receipt = PurchaseReceipt.new(incurred_on: Date.current, category: 'supplies')
  end

  def create
    @receipt = ReceiptWorkflow.new.create(receipt_params, params.dig(:purchase_receipt, :file))
    redirect_to receipt_path(@receipt), notice: 'Receipt uploaded privately. Review the details, then submit for approval.'
  end

  def show
    @events = @receipt.events.includes(:actor).order(:id)
  end

  def edit
    raise ReceiptWorkflow::Error, 'Only your own draft can be edited.' unless @receipt.submitted_by_id == Current.user.id && @receipt.status == 'draft'
  end

  def update
    ReceiptWorkflow.new.change(@receipt, :update, attributes: receipt_params, version: params.dig(:purchase_receipt, :lock_version))
    redirect_to receipt_path(@receipt), notice: 'Receipt details updated.'
  end

  %i[submit approve reject reopen].each do |event|
    define_method(event) do
      ReceiptWorkflow.new.change(@receipt, event, version: params[:lock_version], note: params[:review_note], confirmed: params[:confirmed])
      redirect_to receipt_path(@receipt), notice: { submit: 'Receipt submitted for approval.', approve: 'Receipt approved.', reject: 'Receipt returned for correction.', reopen: 'Receipt reopened as a draft.' }.fetch(event)
    end
  end

  def download
    send_data @receipt.original_bytes, filename: "receipt-#{@receipt.id}.#{@receipt.filename.split('.').last}", type: @receipt.content_type, disposition: 'attachment'
    log_export('Purchase receipt', "Receipt #{@receipt.id}")
  end

  private

  def prevent_caching
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
  end

  def set_receipt
    @receipt = PurchaseReceipt.visible_to(Current.user).find(params[:id])
  end

  def receipt_params
    params.require(:purchase_receipt).permit(:payee, :incurred_on, :amount, :category, :notes).to_h
  end

  def workflow_error(error)
    message = error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.to_sentence : error.message
    if action_name == 'create'
      @receipt = PurchaseReceipt.new(receipt_params)
      @form_error = message
      render :new, status: :unprocessable_entity
    elsif action_name == 'update'
      redirect_to edit_receipt_path(@receipt), alert: message
    else
      redirect_to(@receipt&.persisted? ? receipt_path(@receipt) : receipts_path, alert: message)
    end
  end
end
