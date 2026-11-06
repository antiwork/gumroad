# frozen_string_literal: true

# Settings / Main
class UserPolicy < ApplicationPolicy
  def deactivate?
    user.role_owner_for?(seller)
  end

  def generate_product_details_with_ai?
    seller.eligible_for_ai_product_generation? && (user.is_team_member? || user.id == seller.id || user.role_admin_for?(seller) || user.role_marketing_for?(seller))
  end

  # Whether this user's ROLE lets them open the Agent tab: owner, admin or marketing. There is no
  # earned-access bar, since connecting an AI through MCP is open to every seller.
  def view_store_agent?
    user.id == seller.id || user.role_admin_for?(seller) || user.role_marketing_for?(seller)
  end
end
