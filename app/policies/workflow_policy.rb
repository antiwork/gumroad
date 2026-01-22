# frozen_string_literal: true

# Associated with Posts section
#
class WorkflowPolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def create?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def new?
    create?
  end

  def edit?
    create?
  end

  def show?
    create?
  end

  def emails?
    create?
  end

  def update?
    create?
  end

  def create_post_and_rule?
    create?
  end

  def create_and_publish_post_and_rule?
    create?
  end

  def delete?
    create?
  end

  def destroy?
    create?
  end

  def save_installments?
    create?
  end
end
