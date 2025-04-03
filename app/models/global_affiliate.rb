# frozen_string_literal: true

class GlobalAffiliate < Affiliate
  AFFILIATE_COOKIE_LIFETIME_DAYS = 7
  AFFILIATE_BASIS_POINTS = 1000

  validates :affiliate_user_id, uniqueness: true
  validates :affiliate_basis_points, presence: true

  before_validation :set_affiliate_basis_points, unless: :persisted?

  def self.cookie_lifetime
    AFFILIATE_COOKIE_LIFETIME_DAYS.days
  end

  def final_destination_url(product: nil)
    product.present? ? product.long_url : Rails.application.routes.url_helpers.discover_url(Affiliate::SHORT_QUERY_PARAM => external_id_numeric, host: UrlService.discover_domain_with_protocol)
  end

  def eligible_for_purchase_credit?(product:, **opts)
    eligible_for_credit? && product.recommendable? && opts[:purchaser_email] != affiliate_user.email && !product.user.disable_global_affiliate &&
      !product.user.has_brazilian_stripe_connect_account?
  end

  private
    def set_affiliate_basis_points
      self.affiliate_basis_points = AFFILIATE_BASIS_POINTS
    end
end
