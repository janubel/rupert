# frozen_string_literal: true

class CustomerPolicy < ApplicationPolicy
  def index?
    tenant? && module?('customers.read')
  end

  def show?
    index?
  end

  def create?
    tenant? && module?('customers.write')
  end

  def new?
    create?
  end

  def update?
    create?
  end

  def edit?
    create?
  end
end
