# frozen_string_literal: true

# Ai::StoreAgentScopes resolves WHICH OAuth scopes the agent's short-lived token may carry for a
# given acting user, based on that user's team role for the seller.
#
# Why this exists (security):
#   The agent replays the real public v2 API with a token whose resource owner is always the STORE
#   OWNER (so the right records resolve). The v2 API authenticates the token's resource owner and
#   gates each endpoint by SCOPE only — it never consults the acting team member's role. Left
#   unchecked, a non-owner teammate allowed on the Agent tab (e.g. a marketing member) would inherit
#   the owner's full scope set and could read payouts/tax data or issue refunds that the dashboard's
#   Pundit rules deny for their role.
#
#   So we mint the token with only the subset of scopes the acting user's role is actually allowed,
#   mirroring the dashboard Pundit policies. An endpoint outside that subset then 403s at the v2
#   layer exactly as it would in the dashboard. This is the real boundary; the service/executor add
#   a defense-in-depth pre-check on top so a denied endpoint is refused before any dispatch.
#
# Role -> scope mapping is grounded in the existing dashboard policies (the source of truth):
#   - Content (products, sales reads, emails, profile): LinkPolicy#new?, Audience::PurchasePolicy
#     #index?, WorkflowPolicy#create?, ProfileSectionPolicy#update? -> admin OR marketing.
#   - Financial / sensitive writes (payouts, tax data, sale edits/refunds/shipping):
#     BalancePolicy#index?, Audience::PurchasePolicy#update?/refund?/mark_as_shipped? -> admin (and
#     accountant/support, but those roles can't reach the Agent tab; see UserPolicy#use_store_agent?).
#     NOT marketing. We default-deny these to non-admins.
#
# `account` + `view_public` are the always-required baseline (Api::V2::BaseController appends
# :account to every authorize! check). The owner satisfies every role_*_for? predicate, so the owner
# always gets the full set.
module Ai::StoreAgentScopes
  # Required on every token (the v2 base controller appends :account to each endpoint's check).
  BASELINE_SCOPES = %w[view_public account].freeze

  # Reads/writes the dashboard grants to admin OR marketing.
  CONTENT_SCOPES = %w[edit_products view_sales edit_emails view_profile edit_profile].freeze

  # Financial and sensitive sale-mutation scopes the dashboard restricts to admin (among Agent-tab
  # roles). Marketing is denied these in the dashboard, so the agent denies them too.
  FINANCIAL_SCOPES = %w[view_payouts view_tax_data edit_sales refund_sales mark_sales_as_shipped].freeze

  # The full set the agent OAuth app is registered with. The token is always a SUBSET of this.
  ALL_SCOPES = (BASELINE_SCOPES + CONTENT_SCOPES + FINANCIAL_SCOPES).freeze

  # @param pundit_user [SellerContext] the acting user + seller (user may be a team member)
  # @return [Array<String>] the scopes the acting user's role is allowed to drive through the agent
  def self.permitted_for(pundit_user)
    user = pundit_user&.user
    seller = pundit_user&.seller
    # No authenticated acting user/seller -> no access. (The controllers authorize before we get
    # here; this is a hard fail-closed default.)
    return [] if user.blank? || seller.blank?

    scopes = BASELINE_SCOPES.dup
    scopes.concat(CONTENT_SCOPES) if user.role_admin_for?(seller) || user.role_marketing_for?(seller)
    scopes.concat(FINANCIAL_SCOPES) if user.role_admin_for?(seller)
    scopes.uniq
  end

  # The space-delimited string form the OAuth app is registered with (the superset). Tokens are
  # minted with a narrowed subset of these via #permitted_for.
  def self.all_scopes_string
    ALL_SCOPES.join(" ")
  end
end
