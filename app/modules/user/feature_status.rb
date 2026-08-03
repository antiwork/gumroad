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
      # The only eligibility requirement (beyond country support, which
      # `paypal_connect_enabled?` checks) is that the seller has set up how they
      # receive payouts — a bank account, PayPal payout email, or a connected
      # Stripe/PayPal account. Earlier gates (minimum sales, completed payouts,
      # compliant status) were removed in #6127; see issue #6118.
      has_payout_information?
    end

    def paypal_disconnect_allowed?
      !active_subscribers?(charge_processor_id: PaypalChargeProcessor.charge_processor_id) &&
        !active_preorders?(charge_processor_id: PaypalChargeProcessor.charge_processor_id)
    end

    # True when disconnecting the PayPal Connect account would leave the seller with no way to be
    # paid at all.
    #
    # A seller who has never saved a bank account or a PayPal payout email is still paid out:
    # User#paypal_payout_email falls back to the primary email on the connected PayPal account, and
    # PayoutSchedule#current_payout_processor then routes them to PayPal. That fallback disappears
    # the moment the account is disconnected, and because connecting PayPal requires payout
    # information to already exist (paypal_connect_allowed?), the seller cannot reconnect to undo
    # it. Support has had to restore the payout email by hand, so warn before the click instead.
    #
    # The cheap attribute check comes first so sellers who already have a payout email saved — the
    # common case — never pay for the merchant account lookups.
    def paypal_disconnect_removes_payout_rail?
      payment_address.blank? &&
        active_bank_account.blank? &&
        !has_stripe_account_connected? &&
        has_paypal_account_connected?
    end

    # True when that same disconnect would also stop the seller publishing products. Publishing
    # accepts a couple of things payouts do not (a Gumroad-managed Stripe account, or being a team
    # member), so it is a strictly narrower group than the one above and the warning should only
    # claim it when it holds. Mirrors can_publish_products? with the PayPal term removed.
    def paypal_disconnect_blocks_publishing?
      paypal_disconnect_removes_payout_rail? &&
        !is_team_member? &&
        stripe_account.blank? &&
        stripe_connect_account.blank?
    end

    def can_setup_bank_payouts?
      active_bank_account.present? || (native_payouts_supported? && !signed_up_from_india?) || signed_up_from_united_arab_emirates?
    end

    def can_setup_paypal_payouts?
      # `invalidated_paypal_payout_address` grandfathers the same way `payment_address` does: these
      # sellers qualified only because they had an address on file, and we are the ones who took it
      # off (Payment#invalidate_paypal_payout_address). Without this, invalidating revokes the PayPal
      # option in native-payout countries while the copy we send tells them to add a PayPal account.
      # The refused address itself is still refused, in UpdatePayoutMethod.
      payment_address.present? || invalidated_paypal_payout_address.present? || !native_payouts_supported? || signed_up_from_united_arab_emirates? || signed_up_from_egypt? || signed_up_from_kazakhstan? || signed_up_from_india?
    end

    # True when neither rail can reach the seller's compliance country: we do not offer bank payouts
    # there, and PayPal will not pay into an account registered there either.
    #
    # Messaging only — deliberately gates nothing. A seller here is still payable through a PayPal
    # account registered elsewhere, which is exactly what can_setup_paypal_payouts? keeps open for
    # them, so turning this into a block would strand the one cohort that has a way out.
    def no_payout_rail_in_compliance_country?
      return false if active_bank_account.present?

      country_code = alive_user_compliance_info&.legal_entity_country_code
      return false if country_code.blank?

      !native_payouts_supported? &&
        PaypalPayoutProcessor::PAYOUT_RECEIVING_COUNTRY_CODES.exclude?(country_code)
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
      is_team_member? || stripe_account.present? || stripe_connect_account.present? || paypal_connect_account.present? || payment_address.present?
    end

    def pay_with_paypal_enabled?
      # PayPal sales have been disabled for this creator by admin (mostly due to high chargeback rate)
      return false if disable_paypal_sales?

      # PayPal Connect is not enabled, fallback to old PayPal mode
      return Feature.inactive?(:disable_braintree_sales, self) unless paypal_connect_enabled?

      # If PayPal Connect is supported, check if user has connected a Merchant Account
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
  end
end
