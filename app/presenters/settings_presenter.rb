# frozen_string_literal: true

class SettingsPresenter
  include CurrencyHelper
  include ActiveSupport::NumberHelper

  attr_reader :pundit_user, :seller

  ALL_PAGES = %w(
    main
    profile
    team
    payments
    authorized_applications
    password
    third_party_analytics
    advanced
  ).freeze

  private_constant :ALL_PAGES

  def initialize(pundit_user:)
    @pundit_user = pundit_user
    @seller = pundit_user.seller
  end

  def pages
    @_pages ||= ALL_PAGES.select do |page|
      case page
      when "main", "payments", "password", "third_party_analytics", "advanced"
        Pundit.policy!(pundit_user, [:settings, page.to_sym, seller]).show?
      when "profile"
        Pundit.policy!(pundit_user, [:settings, page.to_sym]).show?
      when "team"
        Pundit.policy!(pundit_user, [:settings, :team, seller]).show?
      when "authorized_applications"
        Pundit.policy!(pundit_user, [:settings, :authorized_applications, OauthApplication]).index? &&
        OauthApplication.alive.authorized_for(seller).present?
      else
        raise StandardError, "Unsupported page `#{page}`"
      end
    end
  end

  def page_title(page)
    case page
    when "main" then "Settings"
    when "authorized_applications" then "Applications"
    when "third_party_analytics" then "Third-party analytics"
    else page.humanize
    end
  end

  def main_props
    {
      settings_pages: pages,
      is_form_disabled: !Pundit.policy!(pundit_user, [:settings, :main, seller]).update?,
      invalidate_active_sessions: Pundit.policy!(pundit_user, [:settings, :main, seller]).invalidate_active_sessions?,
      ios_app_store_url: IOS_APP_STORE_URL,
      android_app_store_url: ANDROID_APP_STORE_URL,
      timezones: ActiveSupport::TimeZone.all.map { |tz| { name: tz.name, offset: tz.formatted_offset } },
      currencies: currency_choices.map { |name, code| { name:, code: } },
      user: {
        email: seller.form_email,
        support_email: seller.support_email,
        locale: seller.locale,
        timezone: seller.timezone,
        currency_type: seller.currency_type,
        has_unconfirmed_email: seller.has_unconfirmed_email?,
        compliance_country: seller.alive_user_compliance_info&.country,
        purchasing_power_parity_enabled: seller.purchasing_power_parity_enabled?,
        purchasing_power_parity_limit: seller.purchasing_power_parity_limit,
        purchasing_power_parity_payment_verification_disabled: seller.purchasing_power_parity_payment_verification_disabled?,
        products: seller.products.visible.map { |product| { id: product.external_id, name: product.name } },
        purchasing_power_parity_excluded_product_ids: seller.purchasing_power_parity_excluded_product_external_ids,
        enable_payment_email: seller.enable_payment_email,
        enable_payment_push_notification: seller.enable_payment_push_notification,
        enable_recurring_subscription_charge_email: seller.enable_recurring_subscription_charge_email,
        enable_recurring_subscription_charge_push_notification: seller.enable_recurring_subscription_charge_push_notification,
        enable_free_downloads_email: seller.enable_free_downloads_email,
        enable_free_downloads_push_notification: seller.enable_free_downloads_push_notification,
        announcement_notification_enabled: seller.announcement_notification_enabled,
        disable_comments_email: seller.disable_comments_email,
        disable_reviews_email: seller.disable_reviews_email,
        show_nsfw_products: seller.show_nsfw_products?,
        disable_affiliate_requests: seller.disable_affiliate_requests?,
        seller_refund_policy:,
        product_level_support_emails: seller.product_level_support_emails_enabled? ? seller.product_level_support_emails : nil
      }
    }
  end

  def application_props(application)
    {
      settings_pages: pages,
      application: {
        id: application.external_id,
        name: application.name,
        redirect_uri: application.redirect_uri,
        icon_url: application.icon_url,
        uid: application.uid,
        secret: application.secret,
      }
    }
  end

  def advanced_props
    if seller.custom_domain&.unverified?
      domain = seller.custom_domain.domain
      has_valid_configuration = CustomDomainVerificationService.new(domain:).process
      message = has_valid_configuration ? "#{domain} domain is correctly configured!"
                  : "Domain verification failed. Please make sure you have correctly configured the DNS record for #{domain}."
      custom_domain_verification_status = { success: has_valid_configuration, message: }
    else
      custom_domain_verification_status = nil
    end

    {
      settings_pages: pages,
      user_id: ObfuscateIds.encrypt(seller.id),
      notification_endpoint: seller.notification_endpoint || "",
      blocked_customer_emails: seller.blocked_customer_objects.active.email.pluck(:object_value).join("\n"),
      custom_domain_verification_status:,
      custom_domain_name: seller.custom_domain&.domain || "",
      applications: seller.oauth_applications.alive.map do |oauth_application|
        {
          id: oauth_application.external_id,
          name: oauth_application.name,
          icon_url: oauth_application.icon_url
        }
      end,
      allow_deactivation: Pundit.policy!(pundit_user, [:user]).deactivate?,
      formatted_balance_to_forfeit_on_account_deletion: seller.formatted_balance_to_forfeit(:account_closure),
    }
  end

  def profile_props
    {
      settings_pages: pages
    }
  end

  def third_party_analytics_props
    {
      disable_third_party_analytics: seller.disable_third_party_analytics,
      google_analytics_id: seller.google_analytics_id || "",
      facebook_pixel_id: seller.facebook_pixel_id || "",
      skip_free_sale_analytics: seller.skip_free_sale_analytics,
      facebook_meta_tag: seller.facebook_meta_tag || "",
      enable_verify_domain_third_party_services: seller.enable_verify_domain_third_party_services,
      snippets: seller.third_party_analytics.alive.map do |third_party_analytic|
        {
          id: third_party_analytic.external_id,
          product: third_party_analytic.link&.unique_permalink,
          name: third_party_analytic.name.presence || "",
          location: third_party_analytic.location,
          code: third_party_analytic.analytics_code,
        }
      end
    }
  end

  def password_props
    {
      require_old_password: seller.provider.blank?,
      settings_pages: pages,
    }
  end

  def authorized_applications_props
    authorized_applications = OauthApplication.alive.authorized_for(seller)
    application_grants = {}
    valid_applications = []

    authorized_applications.each do |application|
      access_grant = Doorkeeper::AccessGrant.order("created_at").where(application_id: application.id, resource_owner_id: seller.id).first
      next if access_grant.nil?

      valid_applications << application
      application_grants[application.id] = access_grant
    end
    valid_applications = valid_applications.sort_by { |application| application_grants[application.id].created_at }

    authorized_applications = valid_applications.map do |application| {
      name: application.name,
      icon_url: application.icon_url,
      is_own_app: application.owner == seller,
      first_authorized_at: application_grants[application.id].created_at.iso8601,
      scopes: application_grants[application.id].scopes,
      id: application.external_id,
    } end

    {
      settings_pages: pages,
      authorized_applications:
    }
  end

  def payments_props(remote_ip: nil)
    user_compliance_info = seller.fetch_or_build_user_compliance_info
    {
      settings_pages: pages,
      is_form_disabled: !Pundit.policy!(pundit_user, [:settings, :payments, seller]).update?,
      should_show_country_modal: !seller.fetch_or_build_user_compliance_info.country.present? &&
        Pundit.policy!(pundit_user, [:settings, :payments, seller]).set_country?,
      aus_backtax_details: aus_backtax_details(user_compliance_info),
      stripe_connect:,
      countries: Compliance::Countries.for_select.to_h,
      ip_country_code: GeoIp.lookup(remote_ip)&.country_code,
      bank_account_details:,
      paypal_address: seller.payment_address,
      show_verification_section: seller.user_compliance_info_requests.requested.present? && seller.stripe_account.present? && Pundit.policy!(pundit_user, [:settings, :payments, seller]).update?,
      paypal_connect:,
      fee_info: fee_info(user_compliance_info),
      user: user_details(user_compliance_info),
      compliance_info: compliance_info_details(user_compliance_info),
      min_dob_year: Date.today.year - UserComplianceInfo::MINIMUM_DATE_OF_BIRTH_AGE,
      uae_business_types: UserComplianceInfo::BusinessTypes::BUSINESS_TYPES_UAE.map { |code, name| { code:, name: } },
      india_business_types: UserComplianceInfo::BusinessTypes::BUSINESS_TYPES_INDIA.map { |code, name| { code:, name: } },
      canada_business_types: UserComplianceInfo::BusinessTypes::BUSINESS_TYPES_CANADA.map { |code, name| { code:, name: } },
      states:,
      saved_card: CheckoutPresenter.saved_card(seller.credit_card),
      formatted_balance_to_forfeit_on_country_change: seller.formatted_balance_to_forfeit(:country_change),
      formatted_balance_to_forfeit_on_payout_method_change: seller.formatted_balance_to_forfeit(:payout_method_change),
      payouts_paused_internally: seller.payouts_paused_internally?,
      payouts_paused_by: seller.payouts_paused_by_source,
      payouts_paused_for_reason: seller.payouts_paused_for_reason,
      payouts_paused_by_user: seller.payouts_paused_by_user?,
      payout_threshold_cents: seller.minimum_payout_amount_cents,
      minimum_payout_threshold_cents: seller.minimum_payout_threshold_cents,
      payout_frequency: seller.payout_frequency,
      payout_frequency_daily_supported: seller.instant_payouts_supported?,
    }
  end

  def seller_refund_policy
    {
      enabled: seller.account_level_refund_policy_enabled?,
      allowed_refund_periods_in_days: RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.keys.map do
        {
          key: _1,
          value: RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[_1]
        }
      end,
      max_refund_period_in_days: seller.refund_policy.max_refund_period_in_days,
      fine_print: seller.refund_policy.fine_print,
      fine_print_enabled: seller.refund_policy.fine_print.present?,
    }
  end

  private
    def user_details(user_compliance_info)
      {
        country_supports_native_payouts: seller.native_payouts_supported?,
        country_supports_iban: seller.country_supports_iban?,
        need_full_ssn: seller.has_ever_been_requested_for_user_compliance_info_field?(UserComplianceInfoFields::Individual::TAX_ID),
        country_code: user_compliance_info.legal_entity_country_code,
        payout_currency: Country.new(user_compliance_info.country_code).payout_currency,
        is_from_europe: seller.signed_up_from_europe?,
        individual_tax_id_needed_countries: [Compliance::Countries::USA.alpha2,
                                             Compliance::Countries::CAN.alpha2,
                                             Compliance::Countries::HKG.alpha2,
                                             Compliance::Countries::SGP.alpha2,
                                             Compliance::Countries::ARE.alpha2,
                                             Compliance::Countries::MEX.alpha2,
                                             Compliance::Countries::BGD.alpha2,
                                             Compliance::Countries::MOZ.alpha2,
                                             Compliance::Countries::URY.alpha2,
                                             Compliance::Countries::ARG.alpha2,
                                             Compliance::Countries::PER.alpha2,
                                             Compliance::Countries::CRI.alpha2,
                                             Compliance::Countries::CHL.alpha2,
                                             Compliance::Countries::COL.alpha2,
                                             Compliance::Countries::GTM.alpha2,
                                             Compliance::Countries::DOM.alpha2,
                                             Compliance::Countries::BOL.alpha2,
                                             Compliance::Countries::KAZ.alpha2,
                                             Compliance::Countries::PRY.alpha2,
                                             Compliance::Countries::PAK.alpha2],
        individual_tax_id_entered: user_compliance_info.individual_tax_id.present?,
        business_tax_id_entered: user_compliance_info.business_tax_id.present?,
        requires_credit_card: seller.requires_credit_card?,
        can_connect_stripe: seller.can_connect_stripe?,
        is_charged_paypal_payout_fee: seller.charge_paypal_payout_fee?,
        joined_at: seller.created_at.iso8601
      }
    end

    def compliance_info_details(user_compliance_info)
      {
        is_business: user_compliance_info.is_business?,
        business_name: user_compliance_info.business_name,
        business_name_kanji: user_compliance_info.business_name_kanji,
        business_name_kana: user_compliance_info.business_name_kana,
        business_type: user_compliance_info.business_type,
        business_street_address: user_compliance_info.business_street_address,
        business_building_number: user_compliance_info.business_building_number,
        business_street_address_kanji: user_compliance_info.business_street_address_kanji,
        business_street_address_kana: user_compliance_info.business_street_address_kana,
        business_city: user_compliance_info.business_city,
        business_state: user_compliance_info.business_state,
        business_country: user_compliance_info.business_country_code || user_compliance_info.country_code,
        business_zip_code: user_compliance_info.business_zip_code,
        business_phone: user_compliance_info.business_phone,
        job_title: user_compliance_info.job_title,
        first_name: user_compliance_info.first_name,
        last_name: user_compliance_info.last_name,
        first_name_kanji: user_compliance_info.first_name_kanji,
        last_name_kanji: user_compliance_info.last_name_kanji,
        first_name_kana: user_compliance_info.first_name_kana,
        last_name_kana: user_compliance_info.last_name_kana,
        street_address: user_compliance_info.street_address,
        building_number: user_compliance_info.building_number,
        street_address_kanji: user_compliance_info.street_address_kanji,
        street_address_kana: user_compliance_info.street_address_kana,
        city: user_compliance_info.city,
        state: user_compliance_info.state,
        country: user_compliance_info.country_code,
        zip_code: user_compliance_info.zip_code,
        phone: user_compliance_info.phone,
        nationality: user_compliance_info.nationality,
        dob_month: user_compliance_info.birthday.try(:month).to_i,
        dob_day: user_compliance_info.birthday.try(:day).to_i,
        dob_year: user_compliance_info.birthday.try(:year).to_i,
      }
    end

    def bank_account_details
      bank_account = seller.active_bank_account

      {
        show_bank_account: bank_account.present? || seller.native_payouts_supported? || seller.signed_up_from_united_arab_emirates?,
        show_paypal: seller.payment_address.present? || !seller.native_payouts_supported? || seller.signed_up_from_united_arab_emirates?,
        card_data_handling_mode: CardDataHandlingMode.get_card_data_handling_mode(seller),
        is_a_card: bank_account.is_a?(CardBankAccount),
        card: bank_account.is_a?(CardBankAccount) ? {
          type: bank_account.credit_card.card_type,
          number: bank_account.credit_card.visual,
          expiration_date: bank_account.credit_card.expiry_visual,
          requires_mandate: false
        } : nil,
        routing_number: bank_account.present? && !bank_account.is_a?(CardBankAccount) ? bank_account.routing_number : nil,
        account_number_visual: bank_account.present? && !bank_account.is_a?(CardBankAccount) ? bank_account.account_number_visual : nil,
        bank_account: bank_account.present? && !bank_account.is_a?(CardBankAccount) ? {
          account_holder_full_name: bank_account.account_holder_full_name,
        } : nil,
      }
    end

    def aus_backtax_details(user_compliance_info)
      {
        show_au_backtax_prompt: Feature.active?(:au_backtaxes, seller) &&
          seller.au_backtax_owed_cents >= User::MIN_AU_BACKTAX_OWED_CENTS_FOR_CONTACT &&
          AustraliaBacktaxEmailInfo.where(user_id: seller.id).exists?,
        total_amount_to_au: Money.new(seller.au_backtax_sales_cents).format(no_cents_if_whole: false, symbol: true),
        au_backtax_amount: Money.new(seller.au_backtax_owed_cents).format(no_cents_if_whole: false, symbol: true),
        opt_in_date: seller.au_backtax_agreement_date&.strftime("%B %e, %Y"),
        credit_creation_date: seller.credit_creation_date,
        opted_in_to_au_backtax: seller.opted_in_to_australia_backtaxes?,
        legal_entity_name: user_compliance_info.legal_entity_name,
        are_au_backtaxes_paid: seller.paid_for_austalia_backtaxes?,
        au_backtaxes_paid_date: seller.date_paid_australia_backtaxes,
      }
    end

    def stripe_connect
      {
        has_connected_stripe: seller.stripe_connect_account.present?,
        stripe_connect_account_id: seller.stripe_connect_account&.charge_processor_merchant_id,
        stripe_disconnect_allowed: seller.stripe_disconnect_allowed?,
        supported_countries_help_text: "This feature is available in <a href='https://stripe.com/en-in/global'>all countries where Stripe operates</a>, except India, Indonesia, Malaysia, Mexico, Philippines, and Thailand.",
      }
    end

    def paypal_connect
      paypal_merchant_account = seller.merchant_accounts.alive.paypal.first
      if paypal_merchant_account
        payment_integration_api = PaypalIntegrationRestApi.new(seller, authorization_header: PaypalPartnerRestCredentials.new.auth_token)
        merchant_account_response = payment_integration_api.get_merchant_account_by_merchant_id(paypal_merchant_account.charge_processor_merchant_id)
        parsed_response = merchant_account_response.parsed_response
        paypal_merchant_account_email = parsed_response["primary_email"]
      end

      {
        show_paypal_connect: Pundit.policy!(pundit_user, [:settings, :payments, seller]).paypal_connect? && seller.paypal_connect_enabled?,
        allow_paypal_connect: seller.paypal_connect_allowed?,
        unsupported_countries: PaypalMerchantAccountManager::COUNTRY_CODES_NOT_SUPPORTED_BY_PCP.map { |code| ISO3166::Country[code].common_name },
        email: paypal_merchant_account_email,
        charge_processor_merchant_id: paypal_merchant_account&.charge_processor_merchant_id,
        charge_processor_verified: paypal_merchant_account.present? && paypal_merchant_account.charge_processor_verified?,
        needs_email_confirmation: paypal_merchant_account.present? && paypal_merchant_account.meta.present? && paypal_merchant_account.meta["isEmailConfirmed"] == "false",
        paypal_disconnect_allowed: seller.paypal_disconnect_allowed?,
      }
    end

    def states
      {
        us: Compliance::Countries.subdivisions_for_select(Compliance::Countries::USA.alpha2).map { |code, name| { code:, name: } },
        ca: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map { |code, name| { code:, name: } },
        au: Compliance::Countries.subdivisions_for_select(Compliance::Countries::AUS.alpha2).map { |code, name| { code:, name: } },
        mx: Compliance::Countries.subdivisions_for_select(Compliance::Countries::MEX.alpha2).map { |code, name| { code:, name: } },
        ae: Compliance::Countries.subdivisions_for_select(Compliance::Countries::ARE.alpha2).map { |code, name| { code:, name: } },
        ir: Compliance::Countries.subdivisions_for_select(Compliance::Countries::IRL.alpha2).map { |code, name| { code:, name: } },
        br: Compliance::Countries.subdivisions_for_select(Compliance::Countries::BRA.alpha2).map { |code, name| { code:, name: } },
      }
    end

    def fee_info(user_compliance_info)
      processor_fee_percent = (Purchase::PROCESSOR_FEE_PER_THOUSAND / 10.0).round(1)
      processor_fee_percent = processor_fee_percent.to_i == processor_fee_percent ? processor_fee_percent.to_i : processor_fee_percent
      processor_fee_fixed_cents = Purchase::PROCESSOR_FIXED_FEE_CENTS

      discover_fee_percent = (Purchase::GUMROAD_DISCOVER_FEE_PER_THOUSAND / 10.0).round(1)
      discover_fee_percent = discover_fee_percent.to_i == discover_fee_percent ? discover_fee_percent.to_i : discover_fee_percent
      direct_fee_percent = ((seller.custom_fee_per_thousand.presence || Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND) / 10.0).round(1)
      direct_fee_percent = direct_fee_percent.to_i == direct_fee_percent ? direct_fee_percent.to_i : direct_fee_percent
      fixed_fee_cents = Purchase::GUMROAD_FIXED_FEE_CENTS

      if user_compliance_info&.country_code == Compliance::Countries::BRA.alpha2
        {
          card_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: #{direct_fee_percent}% + #{fixed_fee_cents}¢ Gumroad fee + #{processor_fee_percent}% + #{processor_fee_fixed_cents}¢ credit card fee.\n• Discover sales: #{discover_fee_percent}% flat\n",
          connect_account_fee_info_text: "All sales will incur a 0% Gumroad fee.",
          paypal_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: #{direct_fee_percent}% + #{fixed_fee_cents}¢ Gumroad fee + #{processor_fee_percent}% + #{processor_fee_fixed_cents}¢ PayPal fee.\n• Discover sales: #{discover_fee_percent}% flat\n"
        }
      else
        {
          card_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: #{direct_fee_percent}% + #{fixed_fee_cents}¢ Gumroad fee + #{processor_fee_percent}% + #{processor_fee_fixed_cents}¢ credit card fee.\n• Discover sales: #{discover_fee_percent}% flat\n",
          connect_account_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: #{direct_fee_percent}% + #{fixed_fee_cents}¢\n• Discover sales: #{discover_fee_percent}% flat\n",
          paypal_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: #{direct_fee_percent}% + #{fixed_fee_cents}¢ Gumroad fee + #{processor_fee_percent}% + #{processor_fee_fixed_cents}¢ PayPal fee.\n• Discover sales: #{discover_fee_percent}% flat\n",
        }
      end
    end
end
