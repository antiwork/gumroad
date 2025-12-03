# frozen_string_literal: true

# Library section
#
class PurchasePolicy < ApplicationPolicy
  def index?
    user.role_owner_for?(seller)
  end

  def archive?
    index?
  end

  def unarchive?
    index?
  end

  def delete?
    index?
  end

  def send_all_for_purchase?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end
end
