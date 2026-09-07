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
  # Stripe Connect (direct-charge) capabilities snapshot. Checkout must only offer methods
  # the account has activated — Stripe rejects a PaymentIntent that lists anything else.
  # Full hash so new methods don't need a re-fetch. Shape:
  # { "capabilities" => { "cashapp_payments" => "active", ... }, "refreshed_at" => <iso8601> }.
  # Written by RefreshMerchantAccountPaymentMethodAvailabilityWorker; missing means not
  # yet fetched (checkout fails safe). Mapping lives in StripeConnectPaymentMethodAvailabilityService.
  attr_json_data_accessor :stripe_capabilities_snapshot
  # LEGACY ISO8601: Stripe rejected an FX quote because this account settles in a non-USD
  # currency. `currency` still says "usd" (Stripe default_currency); only the quote reveals
  # the real settlement currency. Fresh markers skip the doomed FX round-trip and fall back
  # to USD. Cleared on account.updated. Superseded by the per-currency map below — still
  # honored for pre-map connected-account markers until they expire; new writes go to the map.
  attr_json_data_accessor :settlement_currency_mismatch_noticed_at
  # Per-currency mismatch timestamps: { "eur" => "<iso8601>", ... }. Stripe settlement is
  # per currency (iDEAL/SEPA can make the platform settle EUR in EUR while others stay USD),
  # so a mismatch in one currency says nothing about the rest. Only that currency falls
  # back to USD — on managed and connected accounts alike.
  attr_json_data_accessor :settlement_currency_mismatch_map

  validates :charge_processor_id, presence: true
  validates :charge_processor_merchant_id, presence: true, if: -> { user && charge_processor_alive? }
  validates :charge_processor_merchant_id, uniqueness: { case_sensitive: true, message: "This account is already connected with another Gumroad account" }, allow_blank: true, if: proc { |ma| ma.is_a_gumroad_managed_stripe_account? }

  before_save :schedule_products_recommendability_refresh

  scope :charge_processor_alive, -> { where.not(charge_processor_alive_at: nil).where(charge_processor_deleted_at: nil) }
  scope :charge_processor_verified, -> { where.not(charge_processor_verified_at: nil) }
  scope :charge_processor_unverified, -> { where(charge_processor_verified_at: nil) }
  scope :charge_processor_deleted, -> { where.not(charge_processor_deleted_at: nil) }
  scope :paypal, -> { where(charge_processor_id: PaypalChargeProcessor.charge_processor_id) }
  scope :stripe, -> { where(charge_processor_id: StripeChargeProcessor.charge_processor_id) }
  scope :stripe_connect, -> { stripe.where("json_data->>'$.meta.stripe_connect' = 'true'").where.not(user_id: nil) } # Logic should match method `#is_a_stripe_connect_account?`

  def self.gumroad(charge_processor_id)
    where(user_id: nil, charge_processor_id:).first
  end

  def is_managed_by_gumroad?
    !user_id
  end

  # Stale marker costs a USD checkout instead of buyer currency; account.updated clears early.
  SETTLEMENT_CURRENCY_MISMATCH_TTL = 30.days

  def settlement_currency_mismatch_active?(currency)
    return false if currency.blank?
    return true if fresh_mismatch_timestamp?((settlement_currency_mismatch_map || {})[currency.to_s.downcase])

    # Pre-map blanket marker. Bogus on the shared platform account — never honor it there.
    return false if is_managed_by_gumroad?

    fresh_mismatch_timestamp?(settlement_currency_mismatch_noticed_at)
  end

  # Last-observed mismatch for `currency` (TTL from this write, not the first). Includes
  # the shared platform account — EUR local methods really do settle EUR in EUR there.
  def record_settlement_currency_mismatch!(currency)
    return if currency.blank?

    # Read-modify-write: without the row lock, two concurrent currencies can each copy
    # the old map and the last save drops the other marker.
    with_lock do
      map = (settlement_currency_mismatch_map || {}).dup
      map[currency.to_s.downcase] = Time.current.iso8601
      self.settlement_currency_mismatch_map = map
      save!
    end
  end

  # account.updated: webhook doesn't name the currency, so clear the whole map. Cost of
  # over-clearing is one extra FX quote per currency.
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
    clear_non_hash_json_data_for_disconnect!
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
    # JsonData#json_data raises ArgumentError on non-Hash, which aborts mark_deleted! validations
    # and meta=. Reset corrupt metadata so disconnect can finish. Discover refresh still sees the
    # prior value via changes_to_save on the first save.
    def clear_non_hash_json_data_for_disconnect!
      data = self[:json_data]
      return if data.nil? || data.is_a?(Hash)

      self[:json_data] = {}
    end

    def schedule_products_recommendability_refresh
      current_attributes = attributes
      previous_attributes = current_attributes.merge(changes_to_save.transform_values(&:first))
      previous_user_id = recommendation_payout_account_user_id_for(previous_attributes)
      current_user_id = recommendation_payout_account_user_id_for(current_attributes)
      return if previous_user_id == current_user_id

      affected_user_ids = [previous_user_id, current_user_id].compact.uniq
      AfterCommitEverywhere.after_commit { enqueue_products_recommendability_refresh(affected_user_ids) }
    end

    def recommendation_payout_account_user_id_for(account_attributes)
      return if account_attributes["user_id"].blank?
      return if account_attributes["deleted_at"].present?
      return if account_attributes["charge_processor_alive_at"].blank?
      return if account_attributes["charge_processor_deleted_at"].present?

      charge_processor_id = account_attributes["charge_processor_id"]
      json_data = account_attributes["json_data"] || {}
      stripe_connect = if json_data.is_a?(Hash)
        json_data.dig("meta", "stripe_connect") == "true"
      else
        # Non-Hash metadata is the same shape the backfill treats as a connected payout account.
        true
      end
      connected_account = charge_processor_id == PaypalChargeProcessor.charge_processor_id ||
                          (charge_processor_id == StripeChargeProcessor.charge_processor_id && stripe_connect)
      account_attributes["user_id"] if connected_account
    end

    def enqueue_products_recommendability_refresh(affected_user_ids)
      affected_user_ids.each { |affected_user_id| enqueue_products_recommendability_refresh_for(affected_user_id) }
    end

    def enqueue_products_recommendability_refresh_for(affected_user_id)
      return if user_has_another_payout_method?(affected_user_id)

      RefreshMerchantAccountProductsRecommendationEligibilityJob.perform_async(affected_user_id)
    rescue => enqueue_error
      report_recommendability_refresh_error(enqueue_error, "enqueue", affected_user_id)
    end

    def user_has_another_payout_method?(affected_user_id)
      affected_user = User.find_by(id: affected_user_id)
      return false if affected_user.nil?
      return true if affected_user.payment_address.present? || affected_user.active_bank_account.present?

      affected_user.merchant_accounts
        .alive
        .charge_processor_alive
        .where.not(id:)
        .any? { |account| account.is_a_paypal_connect_account? || account.is_a_stripe_connect_account? }
    end

    def report_recommendability_refresh_error(error, action, affected_user_id)
      Rails.logger.error("Failed to #{action} product recommendation refresh for merchant account #{id}, user #{affected_user_id}: #{error.class}: #{error.message}")
      ErrorNotifier.notify(error, merchant_account_id: id, user_id: affected_user_id)
    rescue
      nil
    end

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
