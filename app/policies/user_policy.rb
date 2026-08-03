# frozen_string_literal: true

# Settings / Main
class UserPolicy < ApplicationPolicy
  def deactivate?
    user.role_owner_for?(seller)
  end

  def generate_product_details_with_ai?
    seller.eligible_for_ai_product_generation? && (user.is_team_member? || user.id == seller.id || user.role_admin_for?(seller) || user.role_marketing_for?(seller))
  end

  # Whether this user's ROLE lets them near the Agent tab at all: owner, admin or marketing, since
  # the agent can read store data and propose store changes. Deliberately excludes the earned-access
  # bar, so a seller under it still reaches the tab and gets told why it is locked rather than
  # having the nav item disappear on them.
  def view_store_agent?
    seller.eligible_for_store_agent? && (user.id == seller.id || user.role_admin_for?(seller) || user.role_marketing_for?(seller))
  end

  # Whether they can actually talk to the agent. Every mutating/streaming agent endpoint authorizes
  # against this, so the earned-access bar (User#eligible_for_store_agent?) stays a real boundary
  # even though the tab renders without it.
  def use_store_agent?
    view_store_agent? && seller.eligible_for_store_agent?
  end
end
