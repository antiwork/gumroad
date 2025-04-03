# frozen_string_literal: true

# Posts section
#
class InstallmentPolicy < ApplicationPolicy
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

  def update?
    create?
  end

  def destroy?
    create?
  end

  def publish?
    create?
  end

  def schedule?
    create?
  end

  def delete?
    create?
  end

  def redirect_from_purchase_id?
    create?
  end

  def preview?
    index?
  end

  def updated_recipient_count?
    create?
  end

  def updated_audience_count?
    create?
  end

  def send_for_purchase?
    create? ||
    user.role_support_for?(seller)
  end
end
