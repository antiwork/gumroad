# frozen_string_literal: true

class Affiliate < ApplicationRecord
  include ExternalId
  include Deletable
  include CurrencyHelper
  include FlagShihTzu
  include Affiliate::AudienceMember
  self.ignored_columns = %w(archived_at)

  AFFILIATE_COOKIE_NAME_PREFIX = "_gumroad_affiliate_id_"
  QUERY_PARAM = "affiliate_id"
  SHORT_QUERY_PARAM = "a"
  QUERY_PARAMS = [QUERY_PARAM, SHORT_QUERY_PARAM]

  belongs_to :affiliate_user, class_name: "User"
  has_many :affiliate_credits
  has_many :purchases
  has_many :product_affiliates, autosave: true
  has_many :products, through: :product_affiliates
  has_many :purchases_that_count_towards_volume, -> { counts_towards_volume }, class_name: "Purchase"

  scope :created_after,   ->(start_at) { where("affiliates.created_at > ?", start_at) if start_at.present? }
  scope :created_before,  ->(end_at) { where("affiliates.created_at < ?", end_at) if end_at.present? }

  has_flags 1 => :apply_to_all_products,
            2 => :send_posts,
            3 => :dont_show_as_co_creator,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  scope :by_external_variant_ids_or_products, ->(external_variant_ids, product_ids) do
    return unless external_variant_ids.present? || product_ids.present?
    purchases = Purchase.by_external_variant_ids_or_products(external_variant_ids, product_ids)
    joins(:affiliate_user).where(affiliate_user: { email: purchases.pluck(:email) })
  end

  scope :direct_affiliates, -> { where(type: DirectAffiliate.name) }
  scope :global_affiliates, -> { where(type: GlobalAffiliate.name) }
  scope :direct_or_global_affiliates, -> { where(type: [DirectAffiliate.name, GlobalAffiliate.name]) }

  scope :pending_collaborators, -> { merge(Collaborator.invitation_pending) }
  scope :confirmed_collaborators, -> { merge(Collaborator.invitation_accepted) }
  scope :pending_or_confirmed_collaborators, -> { where(type: Collaborator.name) }

  scope :for_product, ->(product) do
    affiliates_relation = Affiliate.joins("LEFT OUTER JOIN affiliates_links ON affiliates_links.affiliate_id = affiliates.id").where("affiliates_links.link_id = ?", product.id).direct_affiliates
    affiliates_relation = affiliates_relation.or(Affiliate.global_affiliates) if product.recommendable?
    affiliates_relation
  end
  # Logic in `valid_for_product` scope should match logic in `eligible_for_purchase_credit?` methods
  scope :valid_for_product, ->(product) { for_product(product).alive.joins(:affiliate_user).merge(User.not_suspended) }

  validate :eligible_for_stripe_payments
  def enabled_products
    product_affiliates
      .joins(:product)
      .merge(Link.alive)
      .select("affiliates_links.*, links.unique_permalink, links.name")
      .map do
        {
          id: ObfuscateIds.encrypt_numeric(_1.link_id),
          name: _1.name,
          fee_percent: _1.affiliate_percentage || affiliate_percentage,
          destination_url: _1.destination_url,
          referral_url: construct_permalink(_1.unique_permalink)
        }
      end
  end

  def affiliate_info
    {
      id: external_id,
      email: affiliate_user.email,
      destination_url:,
      affiliate_user_name: affiliate_user.display_name(prefer_email_over_default_username: true),
      fee_percent: affiliate_percentage,
    }
  end

  def referral_url
    "#{PROTOCOL}://#{ROOT_DOMAIN}/a/#{external_id_numeric}"
  end

  def referral_url_for_product(product)
    construct_permalink(product.unique_permalink)
  end

  def affiliate_percentage
    return if affiliate_basis_points.nil?
    affiliate_basis_points / 100
  end

  def basis_points(*)
    affiliate_basis_points
  end

  def cookie_key
    "#{AFFILIATE_COOKIE_NAME_PREFIX}#{external_id}"
  end

  def collaborator?
    type == Collaborator.name
  end

  def global?
    type == GlobalAffiliate.name
  end

  def total_cents_earned_formatted
    formatted_dollar_amount(total_cents_earned, with_currency: affiliate_user.should_be_shown_currencies_always?)
  end

  def total_cents_earned
    purchases.paid.not_chargedback_or_chargedback_reversed.sum(:affiliate_credit_cents)
  end

  def eligible_for_credit?
    alive? && !affiliate_user.suspended? && !affiliate_user.has_brazilian_stripe_connect_account?
  end

  private
    def construct_permalink(unique_permalink)
      "#{referral_url}/#{unique_permalink}"
    end

    def eligible_for_stripe_payments
      errors.add(:base, "This user cannot be added as #{collaborator? ? "a collaborator" : "an affiliate"} because they use a Brazilian Stripe account.") if affiliate_user&.has_brazilian_stripe_connect_account?
    end
end
