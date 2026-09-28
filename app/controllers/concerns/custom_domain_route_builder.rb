# frozen_string_literal: true

module CustomDomainRouteBuilder
  extend ActiveSupport::Concern

  included do
    before_action :set_is_user_custom_domain

    helper_method :build_view_post_route
  end

  def build_view_post_route(post:, purchase_id: nil)
    return if post&.slug.blank?

    if @is_user_custom_domain
      custom_domain_view_post_path(slug: post.slug, purchase_id: purchase_id.presence,
                                   protocol: request.protocol)
    else
      view_post_path(
        username: post.user.username.presence || post.user.external_id,
        slug: post.slug,
        purchase_id: purchase_id.presence
      )
    end
  end

  # PROTOCOL, not request.protocol: the edge terminates TLS, so the origin sees the
  # request as http and inheriting its scheme emitted http canonical/og:url on https pages.
  def seller_custom_domain_url
    root_url(protocol: PROTOCOL, host: request.host_with_port) if @is_user_custom_domain
  end

  private
    def set_is_user_custom_domain
      @is_user_custom_domain = UserCustomDomainRequestService.valid?(request)
    end
end
