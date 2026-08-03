# frozen_string_literal: true

module Purchase::Risk
  IP_PROXY_THRESHOLD = 2
  CHECK_FOR_FRAUD_TIMEOUT_SECONDS = 4
  CHARGEBACK_GRACE_PERIOD = 1.year
  CHARGEBACK_GRACE_LIMIT = 1

  # Shown when an identifier-level block stopped the purchase. Deliberately suggests nothing the
  # payer can change themselves: we cannot see from here which identifiers are blocked, and every
  # self-service suggestion we have tried sent people around a loop that could not end
  # (gumroad-private#1480, gumroad-private#1755). Support is the only route that always works.
  BLOCKED_IDENTIFIER_ERROR = "Your card was not charged. This payment could not be completed — please contact support@gumroad.com for help."

  def check_for_fraud
    Timeout.timeout(CHECK_FOR_FRAUD_TIMEOUT_SECONDS) do
      check_for_past_blocked_email_domains
      return if errors.present?

      check_for_past_blocked_guids
      return if errors.present?

      check_for_past_chargebacks
      return if errors.present?

      check_for_past_fraudulent_buyers
      return if errors.present?

      check_for_past_fraudulent_ips
    end
  rescue Timeout::Error => e
    # ErrorNotifier.notify(e)
    logger.info("Check for fraud: Could not check for fraud for purchase #{id}. Exception: #{e.message}")
    nil
  end

  def find_past_chargebacked_purchases
    @_find_past_chargebacked_purchases_for_purchases ||= begin
      past_email_purchases = Purchase.where(email:).chargedback.not_chargeback_reversed.order(chargeback_date: :desc)
      past_guid_purchases = Purchase.where("browser_guid is not null").where(browser_guid:).chargedback.not_chargeback_reversed.order(chargeback_date: :desc)

      past_email_purchases + past_guid_purchases
    end
  end

  private
    def vague_error_message
      record = if is_gift_receiver_purchase
        gift_received&.gifter_purchase || self
      else
        self
      end
      if record.free_purchase?
        "The transaction could not complete."
      else
        "Your card was not charged."
      end
    end

    def check_for_past_blocked_email_domains
      return unless blocked_by_email_domain_if_fraudulent_transaction?

      self.error_code = PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN
      errors.add :base, vague_error_message
    end

    def check_for_past_blocked_guids
      return unless past_blocked_object(browser_guid)

      self.error_code = PurchaseErrorCode::BLOCKED_BROWSER_GUID
      # A browser block is usually written alongside a block on the buyer's email address
      # (#block_buyer! does both), so switching browser, network or payment method changes nothing.
      errors.add :base, BLOCKED_IDENTIFIER_ERROR
    end

    def check_for_past_chargebacks
      chargebacked_purchases = find_past_chargebacked_purchases
      return if chargebacked_purchases.none?
      return if chargebacks_within_grace_period?(chargebacked_purchases)

      self.error_code = PurchaseErrorCode::BUYER_CHARGED_BACK
      errors.add :base, "There's an active chargeback on one of your past Gumroad purchases. Please withdraw it by contacting your charge processor and try again later."
    end

    def chargebacks_within_grace_period?(chargebacked_purchases)
      unique_chargebacked_purchases = chargebacked_purchases.uniq do |purchase|
        purchase.bundle_purchase&.id || purchase.id
      end
      return false if unique_chargebacked_purchases.count > CHARGEBACK_GRACE_LIMIT

      unique_chargebacked_purchases.all? { _1.chargeback_date < CHARGEBACK_GRACE_PERIOD.ago }
    end

    def check_for_past_fraudulent_buyers
      buyer_user = User.find_by(email:)
      return unless buyer_user.try(:suspended_for_fraud?)

      self.error_code = PurchaseErrorCode::SUSPENDED_BUYER
      errors.add :base, "Your card was not charged."
    end

    def check_for_past_fraudulent_ips
      return if is_recurring_subscription_charge
      return if free_purchase?

      buyer_ip_addresses = User.where(email: blockable_emails_if_fraudulent_transaction).pluck(:current_sign_in_ip, :last_sign_in_ip, :account_created_ip).flatten.compact.uniq
      seller_ip_addresses = [seller.current_sign_in_ip, seller.last_sign_in_ip, seller.account_created_ip].compact
      buyer_side_ip_addresses = ([ip_address].compact + buyer_ip_addresses).uniq
      ip_addresses_to_check = seller_ip_addresses + buyer_side_ip_addresses
      blocked_ip_addresses = PlatformBlock.active.where(object_value: ip_addresses_to_check).pluck(:object_value)
      return if blocked_ip_addresses.empty?

      # Screen the buyer, never the seller. A block on the seller's own IP rejects every paid
      # purchase on their whole storefront, from any buyer on any network, and surfaces as a card
      # error the buyer cannot act on. If the seller is the problem, that is a flag or a suspension.
      #
      # Matched by SOURCE, not by subtracting the seller's values: an address can be both, and a
      # buyer sitting on a blocked IP still has to be blocked when the seller happens to share it
      # (same office, same CGNAT, seller buying their own product). Subtracting would drop it.
      #
      # The previous carve-out short-circuited on "any seller IP is blocked" and was gated on
      # compliant?, so it both skipped the buyer check outright and excluded every never-reviewed
      # seller — not_reviewed being the initial risk state (gumroad-private#1755).
      return if (blocked_ip_addresses & buyer_side_ip_addresses).empty?

      self.error_code = PurchaseErrorCode::BLOCKED_IP_ADDRESS
      # The blocked address may be the buyer's account IP rather than the one this request came
      # from, and a browser switch never moves an IP at all, so the old "different browser and/or
      # internet connection" wording was advice that frequently could not work.
      errors.add :base, BLOCKED_IDENTIFIER_ERROR
    end

    def past_blocked_object(object)
      object.present? && PlatformBlock.active.find_by(object_value: object).present?
    end
end
