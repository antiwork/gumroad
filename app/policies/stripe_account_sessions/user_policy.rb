# frozen_string_literal: true

class StripeAccountSessions::UserPolicy < ApplicationPolicy
  def create?
    user.role_owner_for?(seller) && record == seller
  end
end
