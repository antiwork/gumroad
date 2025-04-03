# frozen_string_literal: true

module CustomMailerRouteBuilder
  extend ActiveSupport::Concern

  def build_mailer_post_route(post:, purchase: nil)
    return unless post.shown_on_profile? && post.slug.present?
    user = post.user
    if user.custom_domain.present?
      custom_domain_view_post_url(
        slug: post.slug,
        purchase_id: purchase&.external_id,
        host: user.custom_domain.domain
      )
    else
      view_post_url(
        username: user.username.presence || user.external_id,
        slug: post.slug,
        purchase_id: purchase&.external_id,
        host: UrlService.domain_with_protocol
      )
    end
  end
end
