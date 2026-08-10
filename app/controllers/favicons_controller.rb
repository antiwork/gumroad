# frozen_string_literal: true

# Only seller/product hosts get redirected to the owner's avatar — gumroad.com
# itself (and any host we don't resolve an owner for) keeps serving the real
# static /public/favicon.ico, so this must not become the ONLY route for
# /favicon.ico on the canonical domain.
class FaviconsController < ApplicationController
  include CustomDomainConfig

  def show
    user = GumroadDomainConstraint.matches?(request) ? nil : owner_by_domain(request.host)
    return send_file Rails.root.join("public", "favicon.ico"), type: "image/x-icon", disposition: "inline" unless user&.account_active?

    redirect_to user.avatar_url, allow_other_host: true, status: :found
  end

  private
    # user_by_domain (CustomDomainConfig) only resolves domains that carry a
    # :user — a product-owned custom domain has no :user, so this falls back
    # to the product's seller (gp#1966 review).
    def owner_by_domain(host)
      user_by_domain(host) || CustomDomain.find_by_host(host)&.product&.user
    end
end
