# frozen_string_literal: true

# Settings / Main
class UserPolicy < ApplicationPolicy
  def deactivate?
    user.role_owner_for?(seller)
  end

  def generate_product_details_with_ai?
    seller.eligible_for_ai_product_generation? && (user.is_team_member? || user.id == seller.id || user.role_admin_for?(seller) || user.role_marketing_for?(seller))
  end

  # Gate for the conversational store Agent tab. Only the owner or an admin/marketing role for the
  # seller can chat with the agent, since it can read store data and propose store changes.
  def use_store_agent?
    user.id == seller.id || user.role_admin_for?(seller) || user.role_marketing_for?(seller)
  end
end
