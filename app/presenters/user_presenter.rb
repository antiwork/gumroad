# frozen_string_literal: true

class UserPresenter
  include Rails.application.routes.url_helpers

  attr_reader :user

  def initialize(user:)
    @user = user
  end

  def audience_count = user.audience_members.active.count

  def audience_types
    result = []
    result << :customers if user.audience_members.active.where(customer: true).exists?
    result << :followers if user.audience_members.active.where(follower: true).exists?
    result << :affiliates if user.audience_members.active.where(affiliate: true).exists?
    result
  end

  def products_for_filter_box
    user.links.visible.includes(:alive_variants, :skus_alive_not_default, variant_categories_alive: :alive_variants).reject do |product|
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
    can_publish = user.can_publish_products?
    {
      id: user.external_id,
      email: user.email,
      name: user.display_name(prefer_email_over_default_username: true),
      subdomain: user.subdomain,
      avatar_url: user.avatar_url,
      is_buyer: user.is_buyer?,
      time_zone: { name: time_zone.tzinfo.name, offset: time_zone.tzinfo.utc_offset },
      has_published_products: user.products.alive.exists?,
      can_publish_products: can_publish,
      # Only meaningful when can_publish_products is false. Mirrors
      # Link#publish_blocked_message (link.rb) so the editor can tell a seller who has never
      # connected a payout method apart from one whose Stripe setup was rejected, instead of
      # both hitting the same generic "connect a payment method" toast at Publish time.
      publish_blocked_reason: can_publish ? nil : publish_blocked_reason_for(user),
      no_payout_rail_in_compliance_country: user.no_payout_rail_in_compliance_country?,
      # legal_guardian_requirement_met? gates payouts, not can_publish_products? — a minor who
      # saved a bank account before their age put them under the guardian requirement can still
      # publish, then discover payouts are frozen with no signal until they check into Settings.
      # No compliance info on file at all means no guardian requirement can have kicked in yet.
      legal_guardian_requirement_met: user.alive_user_compliance_info.nil? || user.alive_user_compliance_info.legal_guardian_requirement_met?,
      is_name_invalid_for_email_delivery: user.is_name_invalid_for_email_delivery?,
      profile_background_color: user.seller_profile.background_color,
      profile_highlight_color: user.seller_profile.highlight_color,
      profile_font: user.seller_profile.font,
    }
  end

  def author_byline_props(custom_domain_url: nil, recommended_by: nil)
    return if user.username.blank?

    {
      id: user.external_id,
      name: user.name_or_username,
      avatar_url: user.avatar_url,
      profile_url: user.profile_url(custom_domain_url:, recommended_by:),
      is_verified: !!user.verified,
    }
  end

  private
    # Mirrors Link#publish_blocked_message's own two-way branch (link.rb) without duplicating its
    # copy verbatim, since the editor renders this state before a Link even exists (during initial
    # product creation) and needs a machine-readable reason key, not a pre-rendered sentence.
    def publish_blocked_reason_for(user)
      user.latest_payout_setup_rejection_note.present? ? "payout_setup_rejected" : "no_payout_method"
    end
end
