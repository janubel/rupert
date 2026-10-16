# frozen_string_literal: true

class CustomerFollowUpsController < AuthenticatedController
  def create
    customer = Core::Customer.find_by!(tenant_id: Current.tenant_id, id: params[:customer_id])
    authorize(customer, :update?)
    follow_up = customer.follow_ups.new(params.require(:follow_up).permit(:title, :due_on, :owner_id))
    follow_up.author = Current.user
    if follow_up.save
      redirect_to(customer_path(customer), notice: 'Follow-up scheduled.')
    else
      redirect_to(customer_path(customer), alert: follow_up.errors.full_messages.to_sentence)
    end
  end

  def update
    customer = Core::Customer.find_by!(tenant_id: Current.tenant_id, id: params[:customer_id])
    authorize(customer, :update?)
    follow_up = customer.follow_ups.find(params[:id])
    if %w[complete reopen].include?(params[:event])
      follow_up.with_lock { follow_up.update!(completed_at: params[:event] == 'complete' ? Time.current : nil) }
      redirect_to(customer_path(customer), notice: 'Follow-up updated.')
    else
      head(:unprocessable_entity)
    end
  end
end
