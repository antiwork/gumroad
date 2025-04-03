# frozen_string_literal: true

class AffiliateRequests::OnboardingFormPolicy < ApplicationPolicy
  def update?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end
end
