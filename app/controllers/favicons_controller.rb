# frozen_string_literal: true

# /favicon.ico previously always served the generic Gumroad icon from
# /public/favicon.ico, because browsers request it unconditionally and no
# per-seller route existed to intercept that on a subdomain or custom domain
# (gp#1966). Only seller hosts get redirected to the seller's own avatar —
# gumroad.com itself (and any host we don't resolve a seller for) keeps
# serving the real static icon, so this must not become the ONLY route for
# /favicon.ico on the canonical domain.
class FaviconsController < ApplicationController
  include CustomDomainConfig

  def show
    user = GumroadDomainConstraint.matches?(request) ? nil : user_by_domain(request.host)
    return send_file Rails.root.join("public", "favicon.ico"), type: "image/x-icon", disposition: "inline" unless user&.account_active?

    redirect_to user.avatar_url, allow_other_host: true, status: :found
  end
end
