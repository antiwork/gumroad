# frozen_string_literal: true

class Affiliate < ApplicationRecord
  include ExternalId
  include Deletable
  include CurrencyHelper
  include FlagShihTzu

  include AudienceMember, Cookies

  self.ignored_columns = %w(archived_at)

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
    return none if product.nil?

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

  def collaborator?
    type == Collaborator.name
  end

  def global?
    type == GlobalAffiliate.name
  end

  # Accepts an optional pre-computed cents amount so callers that cache the
  # raw sum (an expensive full-history aggregate) can still format it with
  # the affiliate user's current currency-display preference on every call,
  # instead of caching an already-formatted string that would go stale if
  # that preference changes.
  def total_cents_earned_formatted(cents = total_cents_earned)
    formatted_dollar_amount(cents, with_currency: affiliate_user.should_be_shown_currencies_always?)
  end

  # Lifetime earnings across every purchase attributed to this affiliate.
  #
  # For a Gumroad affiliate (GlobalAffiliate) with a long referral history this
  # sums a very large number of purchase rows, and none of the filters it applies
  # can be answered from an index alone, so it can take tens of seconds. Callers
  # that run inside a web request must pass `timeout_ms` so the database gives up
  # instead of holding a worker until the request is killed; see
  # AffiliateEarningsCache, which owns that flow. With `timeout_ms` set, MySQL
  # aborts the query once the limit is reached and raises, which the caller is
  # expected to catch.
  #
  # Note that omitting `timeout_ms` does not mean "no time limit": every
  # connection in this app is opened with a session `max_execution_time` of five
  # minutes (see config/database.yml), so an untimed call is really a call with
  # that cap. A `timeout_ms` larger than the session value raises the ceiling for
  # that one statement, which is how a background caller asks for more time than
  # a request would ever be given.
  def total_cents_earned(timeout_ms: nil)
    scope = purchases.paid.not_chargedback_or_chargedback_reversed
    return scope.sum(:affiliate_credit_cents) if timeout_ms.nil?

    # The optimizer hint has to sit immediately after the SELECT keyword, which
    # is where the plucked expression lands.
    scope.reorder(nil).pick(
      Arel.sql("/*+ MAX_EXECUTION_TIME(#{timeout_ms.to_i}) */ COALESCE(SUM(purchases.affiliate_credit_cents), 0)")
    )
  end

  def eligible_for_credit?
    alive? && !affiliate_user.suspended? && !affiliate_user.has_brazilian_stripe_connect_account?
  end

  # Whether this affiliate should still earn commission on a *renewal* of a membership they
  # originally referred. A renewal inherits the original purchase's affiliate instead of
  # re-resolving one from cookies, so it never goes through `eligible_for_purchase_credit?`.
  # That means any seller-level setting checked only at purchase time would be ignored forever
  # once a membership is attached to an affiliate. Subclasses that have such a setting override
  # this; by default a referral keeps earning for as long as the affiliate is eligible at all.
  def eligible_for_credit_on_renewal?(product:)
    eligible_for_credit?
  end

  private
    def construct_permalink(unique_permalink)
      "#{referral_url}/#{unique_permalink}"
    end

    def eligible_for_stripe_payments
      return if being_marked_as_deleted?
      errors.add(:base, "This user cannot be added as #{collaborator? ? "a collaborator" : "an affiliate"} because they use a Brazilian Stripe account.") if affiliate_user&.has_brazilian_stripe_connect_account?
    end
end
