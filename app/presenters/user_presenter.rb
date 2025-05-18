# frozen_string_literal: true

class UserPresenter
  include Rails.application.routes.url_helpers

  attr_reader :user

  def initialize(user:)
    @user = user
  end

  def audience_count = user.audience_members.count

  def audience_types
    result = []
    result << :customers if user.audience_members.where(customer: true).exists?
    result << :followers if user.audience_members.where(follower: true).exists?
    result << :affiliates if user.audience_members.where(affiliate: true).exists?
    result
  end

  def products_for_filter_box
    user.links.visible.includes(:alive_variants).reject do |product|
      product.archived? && !product.has_successful_sales?
    end
  end

  def affiliate_products_for_filter_box
    user.links.visible.order("created_at DESC").reject do |product|
      product.archived? && !product.has_successful_sales?
    end
  end

  def as_current_seller
    time_zone = ActiveSupport::TimeZone[user.timezone]
    {
      id: user.external_id,
      email: user.email,
      name: user.display_name(prefer_email_over_default_username: true),
      subdomain: user.subdomain,
      avatar_url: user.avatar_url,
      is_buyer: user.is_buyer?,
      time_zone: { name: time_zone.tzinfo.name, offset: time_zone.tzinfo.utc_offset },
      has_published_products: user.products.alive.exists?,
    }
  end

  def author_byline_props(custom_domain_url: nil, recommended_by: nil)
    return if user.username.blank?

    {
      id: user.external_id,
      name: user.name_or_username,
      avatar_url: user.avatar_url,
      profile_url: user.profile_url(custom_domain_url:, recommended_by:)
    }
  end
end
