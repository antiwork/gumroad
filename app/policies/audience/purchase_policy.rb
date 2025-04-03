# frozen_string_literal: true

class Audience::PurchasePolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def update?
    user.role_admin_for?(seller) ||
    user.role_support_for?(seller)
  end

  def refund?
    update?
  end

  def change_can_contact?
    update?
  end

  def cancel_preorder_by_seller?
    update?
  end

  def create_ping?
    update?
  end

  def mark_as_shipped?
    update?
  end

  def manage_license?
    update?
  end

  def revoke_access?
    update? &&
    record.not_is_access_revoked &&
    !record.refunded? &&
    !record.link.is_physical &&
    record.subscription.blank?
  end

  def undo_revoke_access?
    update? &&
    record.is_access_revoked
  end
end
