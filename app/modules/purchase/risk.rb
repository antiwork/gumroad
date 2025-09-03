# frozen_string_literal: true

module Purchase::Risk
  IP_PROXY_THRESHOLD = 2
  CHECK_FOR_FRAUD_TIMEOUT_SECONDS = 4

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
    # Bugsnag.notify(e)
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
      record = is_gift_receiver_purchase ? gift_received.gifter_purchase : self
      if record.free_purchase?
        "The transaction could not complete."
      else
        "Your card was not charged."
      end
    end

    def check_for_past_blocked_email_domains
      return unless BlockedObject.find_active_objects(blockable_email_domains_if_fraudulent_transaction).exists?

      self.error_code = PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN
      errors.add :base, vague_error_message
    end

    def check_for_past_blocked_guids
      return unless past_blocked_object(browser_guid)

      self.error_code = PurchaseErrorCode::BLOCKED_BROWSER_GUID
      errors.add :base, "Your card was not charged. Please try again on a different browser and/or internet connection."
    end

    def check_for_past_chargebacks
      return if find_past_chargebacked_purchases.none?

      self.error_code = PurchaseErrorCode::BUYER_CHARGED_BACK
      errors.add :base, "There's an active chargeback on one of your past Gumroad purchases. Please withdraw it by contacting your charge processor and try again later."
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
      return if Feature.inactive?(:purchase_check_for_fraudulent_ips)

      buyer_ip_addresses = User.where(email: blockable_emails_if_fraudulent_transaction).pluck(:current_sign_in_ip, :last_sign_in_ip, :account_created_ip).flatten.compact.uniq
      ip_addresses_to_check = [seller.current_sign_in_ip, seller.last_sign_in_ip, seller.account_created_ip, ip_address].compact.concat(buyer_ip_addresses)
      return if BlockedObject.find_active_objects(ip_addresses_to_check).count == 0
      return if BlockedObject.find_active_objects(ip_addresses_to_check[0..2]).present? && seller.compliant?

      self.error_code = PurchaseErrorCode::BLOCKED_IP_ADDRESS
      errors.add :base, "Your card was not charged. Please try again on a different browser and/or internet connection."
    end

    def past_blocked_object(object)
      object.present? && BlockedObject.find_active_object(object).present?
    end
end
