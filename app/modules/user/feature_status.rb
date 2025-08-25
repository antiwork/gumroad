# frozen_string_literal: true

##
# A collections of methods that determines user's status with certain features.
##

class User
  module FeatureStatus
    def merchant_migration_enabled?
      check_merchant_account_is_linked || (Feature.active?(:merchant_migration, self) &&
          StripeMerchantAccountManager::COUNTRIES_SUPPORTED_BY_STRIPE_CONNECT.include?(::Compliance::Countries.find_by_name(alive_user_compliance_info&.country)&.alpha2))
    end

    def paypal_connect_enabled?
      alive_user_compliance_info.present? && PaypalMerchantAccountManager::COUNTRY_CODES_NOT_SUPPORTED_BY_PCP.exclude?(::Compliance::Countries.find_by_name(alive_user_compliance_info.country)&.alpha2)
    end

    def paypal_connect_allowed?
      compliant? && sales_cents_total >= PaypalMerchantAccountManager::MIN_SALES_CENTS_REQ_FOR_PCP && has_completed_payouts?
    end

    def paypal_disconnect_allowed?
      !active_subscribers?(charge_processor_id: PaypalChargeProcessor.charge_processor_id) &&
        !active_preorders?(charge_processor_id: PaypalChargeProcessor.charge_processor_id)
    end

    def charge_paypal_payout_fee?
      Feature.active?(:paypal_payout_fee, self) &&
        !paypal_payout_fee_waived? &&
        PaypalPayoutProcessor::PAYPAL_PAYOUT_FEE_EXEMPT_COUNTRY_CODES.exclude?(alive_user_compliance_info&.legal_entity_country_code)
    end

    def stripe_disconnect_allowed?
      !has_stripe_account_connected? ||
          (!active_subscribers?(charge_processor_id: StripeChargeProcessor.charge_processor_id, merchant_account: stripe_connect_account) &&
              !active_preorders?(charge_processor_id: StripeChargeProcessor.charge_processor_id, merchant_account: stripe_connect_account))
    end

    def has_stripe_account_connected?
      merchant_migration_enabled? && stripe_connect_account.present?
    end

    def has_paypal_account_connected?
      paypal_connect_account.present?
    end

    def can_publish_products?
      !(check_merchant_account_is_linked && !merchant_accounts.alive.charge_processor_alive.exists?)
    end

    def pay_with_paypal_enabled?
      # PayPal sales have been disabled for this creator by admin (mostly due to high chargeback rate)
      return false if disable_paypal_sales?

      # Paypal Connect is not enabled, fallback to old Paypal mode
      return Feature.inactive?(:disable_braintree_sales, self) unless paypal_connect_enabled?

      # If Paypal Connect is supported, check if user has connected a Merchant Account
      merchant_accounts.alive.charge_processor_alive.paypal.exists?
    end

    def pay_with_card_enabled?
      return true unless check_merchant_account_is_linked?

      merchant_accounts.alive.charge_processor_alive.stripe.exists?
    end

    def native_paypal_payment_enabled?
      merchant_account(PaypalChargeProcessor.charge_processor_id).present?
    end

    def has_payout_information?
      active_bank_account.present? || payment_address.present? || has_stripe_account_connected? || has_paypal_account_connected?
    end

    def can_disable_vat?
      false
    end

    def waive_gumroad_fee_on_new_sales?
      timezone_for_gumroad_day = gumroad_day_timezone.presence || timezone
      is_today_gumroad_day = Time.now.in_time_zone(timezone_for_gumroad_day).to_date == $redis.get(RedisKey.gumroad_day_date)&.to_date
      is_today_gumroad_day || Feature.active?(:waive_gumroad_fee_on_new_sales, self)
    end

    def product_level_support_emails_enabled?
      Feature.active?(:product_level_support_emails, self)
    end
  end
end
