# frozen_string_literal: true

class MerchantAccount < ApplicationRecord
  include Deletable
  include ExternalId
  include JsonData
  include ChargeProcessable

  belongs_to :user, optional: true
  has_many :purchases
  has_many :credits
  has_many :balances
  has_many :balance_transactions
  has_many :charges

  attr_json_data_accessor :meta
  attr_json_data_accessor :unclaimed_balance_collection_transfer_id
  attr_json_data_accessor :stripe_disabled_reason
  attr_json_data_accessor :stripe_payouts_pause_email_sent
  attr_json_data_accessor :stripe_payouts_pause_email_claim_token
  attr_json_data_accessor :stripe_rejection_email_sent
  # For Stripe Connect (direct-charge) accounts: a cached snapshot of the account's Stripe
  # capabilities. Charges for these sellers are created on their account, not Gumroad's platform
  # account, and Stripe rejects a PaymentIntent whose payment_method_types lists a method the
  # account hasn't activated — so checkout must only offer what the account actually supports.
  # The FULL capabilities hash is stored (not just the methods consulted today) so future payment
  # method launches read from existing snapshots without a re-fetch sweep. Shape:
  # { "capabilities" => { "cashapp_payments" => "active", ... }, "refreshed_at" => <iso8601> }.
  # Refreshed by RefreshMerchantAccountPaymentMethodAvailabilityWorker (Stripe account.updated /
  # capability.updated webhooks, plus a lazy checkout-time backfill). A missing snapshot means
  # "not yet fetched" and checkout fails safe. Read via
  # StripeConnectPaymentMethodAvailabilityService, which owns the method-type → capability mapping.
  attr_json_data_accessor :stripe_capabilities_snapshot
  # Learned marker that Stripe rejected an FX quote for this account because the account
  # settles payments in a non-USD currency (Stripe multi-currency settlement). The stored
  # `currency` column mirrors Stripe's default_currency, which for these accounts still says
  # "usd" — only Stripe's answer at quote time reveals the real settlement currency, so the
  # first rejected quote records it here. While the marker is fresh (see
  # SETTLEMENT_CURRENCY_MISMATCH_TTL), buyer-currency eligibility skips the doomed FX-quote
  # round trip on every checkout and falls back to canonical USD immediately. The marker
  # expires on its own and is cleared by the Stripe account.updated webhook when the
  # account's currency configuration changes, so accounts that stop settling in another
  # currency regain presentment without manual intervention. ISO8601 timestamp string.
  #
  # LEGACY, read-only: superseded by the per-currency map below. Still honored for
  # seller-connected accounts whose marker was written before the per-currency change so
  # they keep their USD fallback until it expires; new mismatches only write the map.
  attr_json_data_accessor :settlement_currency_mismatch_noticed_at
  # Per-currency version of the marker above: { "eur" => "<iso8601>", ... }. Stripe
  # multi-currency settlement is configured PER CURRENCY (e.g. enabling iDEAL/SEPA made
  # the shared platform account settle EUR in EUR while every other currency still
  # settles in USD), so a mismatch observed for one presentment currency says nothing
  # about the others. The 2026-07-21/22 gumroad-private#933 incidents were both blast-radius
  # failures of the single blanket marker: first a blanket marker on the shared account
  # silently suppressed FX quotes for ALL currencies (#6117), then #6117's blanket
  # "never record on managed accounts" guard removed the graceful USD fallback for the
  # one currency that genuinely mismatched, failing every eurozone checkout closed.
  # Scoping the marker to the currency fixes both: only the mismatching currency falls
  # back to USD, on managed and connected accounts alike.
  attr_json_data_accessor :settlement_currency_mismatch_map

  validates :charge_processor_id, presence: true
  validates :charge_processor_merchant_id, presence: true, if: -> { user && charge_processor_alive? }
  validates :charge_processor_merchant_id, uniqueness: { case_sensitive: true, message: "This account is already connected with another Gumroad account" }, allow_blank: true, if: proc { |ma| ma.is_a_gumroad_managed_stripe_account? }

  scope :charge_processor_alive, -> { where.not(charge_processor_alive_at: nil).where(charge_processor_deleted_at: nil) }
  scope :charge_processor_verified, -> { where.not(charge_processor_verified_at: nil) }
  scope :charge_processor_unverified, -> { where(charge_processor_verified_at: nil) }
  scope :charge_processor_deleted, -> { where.not(charge_processor_deleted_at: nil) }
  scope :paypal, -> { where(charge_processor_id: PaypalChargeProcessor.charge_processor_id) }
  scope :stripe, -> { where(charge_processor_id: StripeChargeProcessor.charge_processor_id) }
  scope :stripe_connect, -> { stripe.where("json_data->>'$.meta.stripe_connect' = 'true'").where.not(user_id: nil) } # Logic should match method `#is_a_stripe_connect_account?`

  # Public: Get Gumroad's merchant account on the charge processor.
  #
  # charge_processor_id – The charge processor to get a MerchantAccount for.
  #
  # Returns a MerchantAccount which is Gumroad's merchant account on the given charge processor.
  def self.gumroad(charge_processor_id)
    where(user_id: nil, charge_processor_id:).first
  end

  def is_managed_by_gumroad?
    !user_id
  end

  # How long a learned settlement-currency mismatch (see
  # settlement_currency_mismatch_noticed_at) suppresses FX-quote attempts. Multi-currency
  # settlement is an account-level Stripe configuration that rarely changes, so a long TTL
  # is safe: the only cost of a stale marker is a checkout presented in USD instead of the
  # buyer's currency, and the account.updated webhook clears it early when the seller's
  # currency configuration actually changes.
  SETTLEMENT_CURRENCY_MISMATCH_TTL = 30.days

  # True while a recorded settlement-currency mismatch FOR THIS PRESENTMENT CURRENCY is
  # fresh — checkout should skip the FX-quote round trip for this currency and fall back
  # to canonical USD immediately. Other currencies are unaffected: Stripe configures
  # multi-currency settlement per currency, so each currency learns independently.
  def settlement_currency_mismatch_active?(currency)
    return false if currency.blank?
    return true if fresh_mismatch_timestamp?((settlement_currency_mismatch_map || {})[currency.to_s.downcase])

    # Legacy blanket marker written before the per-currency map existed. The shared
    # Gumroad platform account is exempt: on 2026-07-21 a single stale-session failure
    # recorded the blanket marker there and silently suppressed FX quotes for ~all
    # managed sellers (gumroad-private#933), so a pre-map marker on it is known-bogus.
    return false if is_managed_by_gumroad?

    fresh_mismatch_timestamp?(settlement_currency_mismatch_noticed_at)
  end

  # Records that Stripe just rejected (or redirected) an FX quote or PaymentIntent for
  # this account in `currency`, because the account settles that currency in itself
  # rather than USD (Stripe multi-currency settlement). Refreshes the timestamp on every
  # occurrence so the TTL measures time since the LAST observed mismatch, not the first.
  # Recorded per currency — including on the shared Gumroad-managed platform account,
  # where enabling EUR local methods (iDEAL/SEPA) legitimately made EUR settle in EUR
  # (2026-07-22, gumroad-private#933): the graceful USD fallback must apply there too,
  # but only for the currency that actually mismatched.
  def record_settlement_currency_mismatch!(currency)
    return if currency.blank?

    # Updating the map is a read-modify-write on shared persisted state: two checkouts
    # learning mismatches for different currencies at the same time could each copy the
    # same old map and the last save would drop the other currency's marker. with_lock
    # takes a row lock and reloads the record, so the map read below is fresh and
    # concurrent writers are serialized. Contention is negligible — this only runs on
    # the rare mismatch-observation path, not on every checkout.
    with_lock do
      map = (settlement_currency_mismatch_map || {}).dup
      map[currency.to_s.downcase] = Time.current.iso8601
      self.settlement_currency_mismatch_map = map
      save!
    end
  end

  # Forgets all recorded settlement-currency mismatches. Called from the Stripe
  # account.updated webhook when the account's currency configuration changes, so the next
  # eligible checkout probes Stripe again instead of waiting out the TTL. Clears the whole
  # map (not one currency) because the webhook doesn't say which currency changed, and the
  # only cost of over-clearing is one re-probed FX quote per currency.
  def clear_settlement_currency_mismatch!
    return if settlement_currency_mismatch_noticed_at.blank? && settlement_currency_mismatch_map.blank?

    self.settlement_currency_mismatch_noticed_at = nil
    self.settlement_currency_mismatch_map = nil
    save!
  end

  def can_accept_charges?
    !stripe_charge_processor? ||
        is_a_stripe_connect_account? ||
        Country.new(country).can_accept_stripe_charges?
  end

  # Logic should match `.stripe_connect` scope
  def is_a_stripe_connect_account?
    stripe_charge_processor? &&
        user_id.present? &&
        json_data.dig("meta", "stripe_connect") == "true"
  end

  def is_a_brazilian_stripe_connect_account?
    is_a_stripe_connect_account? && country == Compliance::Countries::BRA.alpha2
  end

  def is_a_paypal_connect_account?
    paypal_charge_processor?
  end

  def is_a_gumroad_managed_stripe_account?
    stripe_charge_processor? && json_data.dig("meta", "stripe_connect") != "true"
  end

  # Public: Returns who holds the funds for charges created for this merchant account.
  def holder_of_funds
    if charge_processor_id.in?(ChargeProcessor.charge_processor_ids)
      ChargeProcessor.holder_of_funds(self)
    else
      # Assume we hold the funds for removed charge processors
      HolderOfFunds::GUMROAD
    end
  end

  def delete_charge_processor_account!
    mark_deleted!
    self.meta = {} unless is_a_stripe_connect_account?
    self.charge_processor_deleted_at = Time.current
    self.charge_processor_alive_at = nil
    self.charge_processor_verified_at = nil
    save!
  end

  def charge_processor_delete!
    case charge_processor_id
    when StripeChargeProcessor.charge_processor_id
      StripeMerchantAccountManager.delete_account(self)
    else
      raise NotImplementedError
    end
  end

  def active?
    alive? && charge_processor_alive?
  end

  def charge_processor_alive?
    charge_processor_alive_at.present? && !charge_processor_deleted?
  end
  alias_method :charge_processor_alive, :charge_processor_alive?

  def charge_processor_verified?
    charge_processor_verified_at.present?
  end

  def charge_processor_unverified?
    charge_processor_verified_at.nil?
  end

  def charge_processor_deleted?
    charge_processor_deleted_at.present?
  end

  def mark_charge_processor_verified!
    return if charge_processor_verified?

    self.charge_processor_verified_at = Time.current
    save!
  end

  def mark_charge_processor_unverified!
    return if charge_processor_unverified?

    self.charge_processor_verified_at = nil
    save!
  end

  def stripe_rejected?
    stripe_disabled_reason.to_s.start_with?("rejected.")
  end

  STRIPE_DISABLED_REASON_DESCRIPTIONS = {
    "requirements.past_due" => "Stripe requires additional verification information that is now past due.",
    "requirements.pending_verification" => "Stripe is verifying the information already submitted; no action is needed right now.",
    "action_required.requested_capabilities" => "Stripe has requested additional information or capabilities for this account.",
    "listed" => "Stripe is reviewing the account against its restricted and prohibited business lists.",
    "under_review" => "Stripe is reviewing the account.",
    "platform_paused" => "Payouts were paused at the platform level.",
    "rejected.fraud" => "Stripe rejected the account for suspected fraud.",
    "rejected.listed" => "Stripe rejected the account because it matched a restricted or prohibited list.",
    "rejected.terms_of_service" => "Stripe rejected the account for a terms of service violation.",
    "rejected.other" => "Stripe rejected the account.",
    "other" => "Stripe disabled payouts on the account."
  }.freeze

  def stripe_disabled_reason_description
    return if stripe_disabled_reason.blank?
    STRIPE_DISABLED_REASON_DESCRIPTIONS[stripe_disabled_reason] || "Stripe disabled payouts on the account."
  end

  def stripe_payouts_paused_comment
    reason = stripe_disabled_reason.presence || "not specified"
    ["Payouts automatically paused by Stripe (disabled reason: #{reason}).", stripe_disabled_reason_description].compact.join(" ")
  end

  def paypal_account_details
    payment_integration_api = PaypalIntegrationRestApi.new(user, authorization_header: PaypalPartnerRestCredentials.new.auth_token)
    paypal_response = payment_integration_api.get_merchant_account_by_merchant_id(charge_processor_merchant_id)

    if paypal_response.success?
      parsed_response = paypal_response.parsed_response
      # Special handling for China as PayPal returns country code as C2 instead of CN
      parsed_response["country"] = "CN" if paypal_response["country"] == "C2"
      parsed_response
    end
  end

  private
    # Shared TTL check for both marker formats (per-currency map values and the legacy
    # blanket timestamp).
    def fresh_mismatch_timestamp?(raw)
      return false if raw.blank?

      noticed_at = Time.zone.parse(raw.to_s)
      return false if noticed_at.nil?

      noticed_at > SETTLEMENT_CURRENCY_MISMATCH_TTL.ago
    rescue ArgumentError
      # A malformed timestamp must never break checkout: treat it as no marker.
      false
    end
end
