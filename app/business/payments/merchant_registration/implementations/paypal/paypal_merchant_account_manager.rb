# frozen_string_literal: true

class PaypalMerchantAccountManager
  attr_reader :response

  # Ref: https://developer.paypal.com/docs/api/reference/country-codes/#paypal-commerce-platform-availability
  COUNTRY_CODES_NOT_SUPPORTED_BY_PCP = [
    Compliance::Countries::DZA,
    Compliance::Countries::BRA,
    Compliance::Countries::EGY,
    Compliance::Countries::IND,
    Compliance::Countries::ISR,
    Compliance::Countries::JPN,
    Compliance::Countries::FSM,
    Compliance::Countries::MAR,
    Compliance::Countries::TUR,
  ].map(&:alpha2).freeze

  MIN_SALES_CENTS_REQ_FOR_PCP = 100_00 # $100

  def create_partner_referral(user, return_url)
    payment_integration_api = PaypalIntegrationRestApi.new(user, authorization_header:)

    @response = payment_integration_api.create_partner_referral(return_url)

    if post_partner_referral_success?
      partner_referral_success_response_data
    else
      notify_bugsnag_partner_referral_error
      partner_referral_failure_response_data
    end
  end

  def handle_paypal_event(paypal_event)
    case paypal_event["event_type"]
    when PaypalEventType::MERCHANT_ONBOARDING_SELLER_GRANTED_CONSENT, PaypalEventType::MERCHANT_ONBOARDING_COMPLETED,
        PaypalEventType::MERCHANT_EMAIL_CONFIRMED, PaypalEventType::MERCHANT_CAPABILITY_UPDATED,
        PaypalEventType::MERCHANT_SUBSCRIPTION_UPDATED
      handle_merchant_account_updated_event(paypal_event)
    when PaypalEventType::MERCHANT_PARTNER_CONSENT_REVOKED, PaypalEventType::MERCHANT_IDENTITY_AUTH_CONSENT_REVOKED
      handle_merchant_consent_revoked_event(paypal_event)
    end
  end

  def update_merchant_account(user:, paypal_merchant_id:, meta: nil,
                              send_email_confirmation_notification: true,
                              create_new: true)
    return "There was an error connecting your PayPal account with Gumroad." if user.blank? || paypal_merchant_id.blank?
    return "Your PayPal account could not be connected because you do not meet the eligibility requirements." unless user.paypal_connect_allowed?

    paypal_merchant_accounts = user.merchant_accounts
                                   .where(charge_processor_id: PaypalChargeProcessor.charge_processor_id)
                                   .where(charge_processor_merchant_id: paypal_merchant_id)

    if create_new
      merchant_account = paypal_merchant_accounts.first_or_initialize
    else
      merchant_account = paypal_merchant_accounts.alive.first
    end

    return unless merchant_account.present?

    merchant_account.deleted_at = nil
    merchant_account.charge_processor_deleted_at = nil
    merchant_account.charge_processor_merchant_id = paypal_merchant_id
    merchant_account.meta = meta if meta.present?

    merchant_account_changed = merchant_account.changed?

    return "There was an error connecting your PayPal account with Gumroad." unless merchant_account.save

    if merchant_account.charge_processor_verified?
      MerchantRegistrationMailer.paypal_account_updated(user.id).deliver_later(queue: "default") if merchant_account_changed
      return "You have successfully connected your PayPal account with Gumroad."
    end

    parsed_response = merchant_account.paypal_account_details

    if parsed_response.present?
      paypal_account_country_code = parsed_response["country"]
      if PaypalMerchantAccountManager::COUNTRY_CODES_NOT_SUPPORTED_BY_PCP.include?(paypal_account_country_code)
        merchant_account.delete_charge_processor_account!
        return "Your PayPal account could not be connected because this PayPal integration is not supported in your country."
      end

      if paypal_account_country_code && parsed_response["primary_currency"]
        merchant_account.country = paypal_account_country_code
        merchant_account.currency = parsed_response["primary_currency"].downcase
        return "There was an error connecting your PayPal account with Gumroad." unless merchant_account.save
      end

      oauth_integration = parsed_response["oauth_integrations"][0]

      if parsed_response["primary_email_confirmed"] && parsed_response["payments_receivable"] &&
          oauth_integration["integration_type"] == "OAUTH_THIRD_PARTY" &&
          oauth_integration["integration_method"] == "PAYPAL"
        oauth_integration["oauth_third_party"][0]["partner_client_id"] == PAYPAL_PARTNER_CLIENT_ID
        merchant_account.charge_processor_alive_at = Time.current
        merchant_account.mark_charge_processor_verified!
        MerchantRegistrationMailer.paypal_account_updated(user.id).deliver_later(queue: "default")
        user.merchant_accounts
            .where(charge_processor_id: PaypalChargeProcessor.charge_processor_id)
            .where.not(id: merchant_account.id).each do |ma|
          ma.delete_charge_processor_account!
        end
        "You have successfully connected your PayPal account with Gumroad."
      elsif parsed_response["primary_email_confirmed"]
        merchant_account.charge_processor_alive_at = nil
        merchant_account.charge_processor_verified_at = nil
        merchant_account.save!
        "Your PayPal account connect with Gumroad is incomplete because of missing permissions. Please try connecting again and grant the requested permissions."
      else
        merchant_account.charge_processor_alive_at = nil
        merchant_account.charge_processor_verified_at = nil
        merchant_account.save!
        MerchantRegistrationMailer.confirm_email_on_paypal(user.id, parsed_response["primary_email"]).deliver_later(queue: "default") if send_email_confirmation_notification
        "You need to confirm the email address (#{parsed_response["primary_email"]}) attached to your PayPal account before you can start using it with Gumroad."
      end
    end
  end

  def disconnect(user:)
    merchant_account = user.merchant_accounts.alive.where(charge_processor_id: PaypalChargeProcessor.charge_processor_id).last
    return false if merchant_account.blank?

    merchant_account.delete_charge_processor_account!
  end

  private
    def authorization_header
      PaypalPartnerRestCredentials.new.auth_token
    end

    def post_partner_referral_success?
      response.success? && post_partner_referral_redirection_url.present?
    end

    def post_partner_referral_redirection_url
      @post_partner_referral_redirection_url ||= response["links"].detect do |link_info|
        link_info.try(:[], "rel") == "action_url"
      end.try(:[], "href")
    end

    def partner_referral_success_response_data
      {
        redirect_url: post_partner_referral_redirection_url,
        success: true
      }
    end

    def partner_referral_failure_response_data
      {
        success: false,
        error_message: partner_referral_error_message
      }
    end

    def response_error_name
      response.parsed_response.try(:[], "name")
    end

    # Error list:
    #   INTERNAL_SERVICE_ERROR
    #   DUPLICATE_REQUEST_ID
    #   VALIDATION_ERROR
    #   INVALID_RESOURCE_ID
    #   PERMISSION_DENIED
    #   DATA_RETRIEVAL
    #   CONNECTION_ERROR
    def partner_referral_error_message
      case response_error_name
      when "VALIDATION_ERROR"
        "Invalid request. Please try again later."
      when "PERMISSION_DENIED"
        "Permission Denied. Please try again later."
      when "CONNECTION_ERROR"
        "Timed out. Please try again later."
      else
        "Please try again later."
      end
    end

    def notify_bugsnag_partner_referral_error
      return if %w[INTERNAL_SERVICE_ERROR PERMISSION_DENIED CONNECTION_ERROR].include?(response_error_name)

      notify_bugsnag
    end

    def notify_bugsnag
      Bugsnag.notify(request: response.request,
                     response:)
    end

    def handle_merchant_account_updated_event(paypal_event)
      paypal_tracking_id = paypal_event["resource"]["tracking_id"]
      return if paypal_tracking_id.blank?

      update_merchant_account(user: User.find_by_external_id(paypal_tracking_id.split("-")[0]),
                              paypal_merchant_id: paypal_event["resource"]["merchant_id"],
                              create_new: false)
    end

    def handle_merchant_consent_revoked_event(paypal_event)
      # IDENTITY.AUTHORIZATION-CONSENT.REVOKED webhook contains payer_id instead of merchant_id
      merchant_id = paypal_event["resource"]["merchant_id"] || paypal_event["resource"]["payer_id"]
      merchant_accounts = MerchantAccount.alive.where(charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                                      charge_processor_merchant_id: merchant_id)

      return if merchant_accounts.blank?

      merchant_accounts.each do |merchant_account|
        merchant_account.delete_charge_processor_account!
        user = merchant_account.user

        MerchantRegistrationMailer.account_deauthorized_to_user(
          user.id,
          PaypalChargeProcessor.charge_processor_id
        ).deliver_later(queue: "critical")
      end
    end
end
