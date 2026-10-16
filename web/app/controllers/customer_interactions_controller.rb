# frozen_string_literal: true

class CustomerInteractionsController < AuthenticatedController
  def create
    customer = Core::Customer.find_by!(tenant_id: Current.tenant_id, id: params[:customer_id])
    authorize(customer, :update?)
    interaction = customer.interactions.new(params.require(:interaction).permit(:kind, :body))
    interaction.author = Current.user
    if interaction.save
      redirect_to(customer_path(customer), notice: 'Interaction recorded.')
    else
      redirect_to(customer_path(customer), alert: interaction.errors.full_messages.to_sentence)
    end
  end
end
