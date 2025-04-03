# frozen_string_literal: true

class CallPolicy < ApplicationPolicy
  def update?
    (user.role_admin_for?(seller) || user.role_support_for?(seller)) && record.purchase.seller == seller
  end

  def permitted_attributes
    [:call_url]
  end
end
