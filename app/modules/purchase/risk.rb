# frozen_string_literal: true

module Purchase::Risk
  IP_PROXY_THRESHOLD = 2
  CHECK_FOR_FRAUD_TIMEOUT_SECONDS = 4

  def pre_charge_fraud_check(randomize_results: false)
    return unless charged_using_gumroad_merchant_account?

    # For "Science of Dogs" we are auto-failing all purchases and based on the logic below, are making the purchases appear successful.
    # If all purchases were successful, it would be obvious to the fraudulent buyer what was happening. For this reason, we are simulating
    # limits and activity based on recent fraudulent behavior.
    #
    # Steps for choosing whether to allow purchase as going through or not:
    #   1. Store stripe_fingerprint in mongo and set card limit based on fake_credit_card_balance_from_distribution method below
    #   2. If stripe_fingerprint starts in A-U and the price is less than the remaining balance, the purchase will appear to be
    #      successful 50% of the time. If it appears to be successful, the price the buyer thinks it has paid will be deducted from
    #      the balance in mongo
    #   3. If the stripe_fingerprint doesn't start in A-U or the card balance has been exceeded, the buyer will be told to verify
    #      their information (same messaging as card declined)

    return unless link.unique_permalink == "lnCj" || email.include?("@example.com")

    if randomize_results
      # check if card fingerprint has been used before and get remaining balance if it has. if it has not been used before,
      # set balance based on fake_credit_card_balance_from_distribution method
      mongo_card_collection = MONGO_DATABASE[MongoCollections::SCIENCE_OF_DOGS_CARDS]
      stripe_fingerprint_card_limits_and_balance = mongo_card_collection.find(stripe_fingerprint:).limit(1).first
      if stripe_fingerprint_card_limits_and_balance.nil?
        remaining_balance = fake_credit_card_balance_from_distribution
        mongo_card_collection.insert_one(stripe_fingerprint:, remaining_card_balance: remaining_balance)
      else
        remaining_balance = stripe_fingerprint_card_limits_and_balance["remaining_card_balance"]
      end

      chance_of_next_purchase_being_successful = $redis.get("chance_of_next_purchase_being_successful") || 0.5

      # check first digit of the card fingerprint (match against A-u), remaining balance, and 1/2 times make the purchase appear
      # successful. decrease the remaining balance in mongo. in all other cases, give general verify yor information prompt
      if /[A-Z]/.match(stripe_fingerprint[0]).present? && price_cents <= remaining_balance &&
         SecureRandom.random_number >= (1 - chance_of_next_purchase_being_successful.to_f)
        mongo_card_collection.find("stripe_fingerprint" => stripe_fingerprint).update_one("$inc" => { "remaining_card_balance" => -price_cents })
        self.error_code = PurchaseErrorCode::FORCED_APPEARANCE_AS_SUCCESSFUL_CHARGE
        errors.add :base
      else
        errors.add :base, I18n.t(:check_card_information_prompt)
        self.error_code = PurchaseErrorCode::FORCED_APPERANCE_AS_FAILED_CHARGE
      end
    else
      self.error_code = PurchaseErrorCode::FORCED_APPEARANCE_AS_SUCCESSFUL_CHARGE
      errors.add :base
    end
  end

  def is_fake_successful_purchase?
    # checks if purchase was faked based on stored error code
    error_code == PurchaseErrorCode::FORCED_APPEARANCE_AS_SUCCESSFUL_CHARGE
  end

  def check_for_fraud
    Timeout.timeout(CHECK_FOR_FRAUD_TIMEOUT_SECONDS) do
      check_for_past_blocked_emails
      return if errors.present?

      check_for_past_blocked_email_domains
      return if errors.present?

      check_for_past_blocked_guids
      return if errors.present?

      check_for_past_chargebacks
      return if errors.present?

      check_for_past_fraudulent_buyers
      return if errors.present?

      check_for_blocked_physical_countries if link.is_physical
      return if errors.present?

      check_for_past_fraudulent_ips
    end
  rescue Timeout::Error => e
    # Bugsnag.notify(e)
    logger.info("Check for fraud: Could not check for fraud for purchase #{id}. Exception: #{e.message}")
    nil
  end

  def safe_mode_check
    return if RiskState.get_ip_proxy_score(ip_address, timeout: 1) <= IP_PROXY_THRESHOLD

    self.error_code = PurchaseErrorCode::SAFE_MODE_HIGH_PROXY_SCORE
    errors.add :base, I18n.t(:check_card_information_prompt)
  end

  def fake_credit_card_balance_from_distribution
    # Simulating stolen credit card starting balance. Half the time, charges of over 1 dollar don't go through,
    # other times the balance is somewhere in the vicinity of 1000, 5000. so we are taking those base amounts (1000, 5000)
    # and adding noise to them and then sampling from (1 * 3, (1000 + noise) * 2, (5000 + noise) * 1)
    if Rails.env.production?
      ([1, 1, 1000 + SecureRandom.random_number(500) * [1, -1].sample, 1000 + SecureRandom.random_number(500) * [1, -1].sample,
        5000 + SecureRandom.random_number(2500) * [1, -1].sample].sample * 100).round(0)
    else
      100_000
    end
  end

  def perform_risk_validations
    perform_risk_analysis
    return if errors.present?

    validate_purchasing_power_parity
    return if errors.present?

    pre_charge_fraud_check(randomize_results: true)
    return if errors.present?

    check_for_past_blocked_charge_processor_fingerprints
    return if errors.present?

    check_for_blocked_customer_emails
  end

  private
    def vague_error_message
      record = is_gift_receiver_purchase ? gift_received.gifter_purchase : self
      if record.free_purchase?
        I18n.t(:vague_purchase_error_notice_for_free_products)
      else
        I18n.t(:vague_purchase_error_notice)
      end
    end

    def check_for_blocked_customer_emails
      blocked_email = blockable_emails_if_fraudulent_transaction.find do |email|
        BlockedCustomerObject.email_blocked?(email:, seller_id:)
      end

      return if blocked_email.blank?

      if charge_processor_fingerprint.present?
        BlockedCustomerObject.block_charge_processor_fingerprint!(fingerprint: charge_processor_fingerprint, email: blocked_email, seller_id:)
      end

      self.error_code = PurchaseErrorCode::BLOCKED_CUSTOMER_EMAIL_ADDRESS
      errors.add :base, I18n.t(:seller_has_blocked_buyer_error_notice)
    end

    def check_for_past_blocked_emails
      return unless BlockedObject.find_active_objects(blockable_emails_if_fraudulent_transaction).exists?

      self.error_code = PurchaseErrorCode::TEMPORARILY_BLOCKED_EMAIL_ADDRESS
      errors.add :base, vague_error_message
    end

    def check_for_past_blocked_charge_processor_fingerprints
      return if charge_processor_fingerprint.blank?

      if BlockedCustomerObject.charge_processor_fingerprint_blocked?(fingerprint: charge_processor_fingerprint, seller_id:)
        self.error_code = PurchaseErrorCode::BLOCKED_CUSTOMER_CHARGE_PROCESSOR_FINGERPRINT
        errors.add :base, I18n.t(:seller_has_blocked_buyer_error_notice)
        return
      end

      Timeout.timeout(CHECK_FOR_FRAUD_TIMEOUT_SECONDS) do
        return if BlockedObject.charge_processor_fingerprint.find_active_object(charge_processor_fingerprint).blank?

        self.error_code = PurchaseErrorCode::BLOCKED_CHARGE_PROCESSOR_FINGERPRINT
        errors.add :base, I18n.t(:vague_purchase_error_notice)
      rescue Timeout::Error => e
        logger.info("Could not check for blocked stripe fingerprints for purchase #{id}. Exception: #{e.message}")
        nil
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
      errors.add :base, I18n.t(:fraudulent_connection_check_failed)
    end

    def check_for_past_chargebacks
      past_email_purchases = Purchase.where(email:).chargedback.not_chargeback_reversed
      past_guid_purchases = Purchase.where("browser_guid is not null").where(browser_guid:).chargedback.not_chargeback_reversed
      return if !past_email_purchases.exists? && !past_guid_purchases.exists?

      self.error_code = PurchaseErrorCode::BUYER_CHARGED_BACK
      errors.add :base, I18n.t(:chargebacks_check_failed)
    end

    def check_for_past_fraudulent_buyers
      buyer_user = User.find_by(email:)
      return unless buyer_user.try(:suspended_for_fraud?)

      self.error_code = PurchaseErrorCode::SUSPENDED_BUYER
      errors.add :base, I18n.t(:vague_purchase_error_notice)
    end

    def check_for_blocked_physical_countries
      buyer_country = GeoIp.lookup(ip_address).try(:country_code)
      country_code = Compliance::Countries.find_by_name(country)&.alpha2 if country
      is_buyer_country_blocked = Compliance::Countries.risk_physical_blocked?(buyer_country)
      is_shipping_country_blocked = country.present? && Compliance::Countries.risk_physical_blocked?(country_code)
      return unless is_buyer_country_blocked || is_shipping_country_blocked

      self.error_code = PurchaseErrorCode::HIGH_RISK_COUNTRY
      errors.add :base, I18n.t(:territory_blocked)
    end

    def check_for_past_fraudulent_ips
      return if is_recurring_subscription_charge
      return if free_purchase?

      buyer_ip_addresses = User.where(email: blockable_emails_if_fraudulent_transaction).pluck(:current_sign_in_ip, :last_sign_in_ip, :account_created_ip).flatten.compact.uniq
      ip_addresses_to_check = [seller.current_sign_in_ip, seller.last_sign_in_ip, seller.account_created_ip, ip_address].compact.concat(buyer_ip_addresses)
      return if BlockedObject.find_active_objects(ip_addresses_to_check).count == 0
      return if BlockedObject.find_active_objects(ip_addresses_to_check[0..2]).present? && seller.compliant?

      self.error_code = PurchaseErrorCode::BLOCKED_IP_ADDRESS
      errors.add :base, I18n.t(:fraudulent_connection_check_failed)
    end

    def check_for_canadian_paypal_scammers
      return if Feature.inactive?(:block_canadian_paypal_scammers)

      return unless charge_processor_id == PaypalChargeProcessor.charge_processor_id
      return unless price_cents == 100
      return unless ip_country == "Canada"
      return unless recommended_by == "search"
      return unless email.length >= 19
      return unless email.ends_with?("@hotmail.com")
      return unless link.price_cents == 0

      self.error_code = PurchaseErrorCode::CANADIAN_PAYPAL_SCAMMER
      errors.add :base, I18n.t(:vague_purchase_error_notice)
    end

    def past_blocked_object(object)
      object.present? && BlockedObject.find_active_object(object).present?
    end

    def log_risk_level_to_mongo(risk_level)
      return if risk_level.blank?

      Mongoer.async_write(MongoCollections::PURCHASE_RISK_LEVELS, "purchase_id" => id, "risk_level" => risk_level, "created_at" => Time.current.iso8601)
    end
end
