# frozen_string_literal: true

class Checkout::SocialProofWidgetPolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def paged?
    index?
  end

  def show?
    index? && when_record_available { record.user == seller }
  end

  def create?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def update?
    create? && when_record_available { record.user == seller }
  end

  def destroy?
    update?
  end

  def duplicate?
    create? && when_record_available { record.user == seller }
  end
end