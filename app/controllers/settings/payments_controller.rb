# frozen_string_literal: true

class Settings::PaymentsController < Sellers::BaseController
  include ActionView::Helpers::SanitizeHelper

  before_action :authorize

  def show
    @title = "Settings"
    @react_component_props = SettingsPresenter.new(pundit_user:).payments_props(remote_ip: request.remote_ip)
  end

  def update
    return render(json: { success: false, error_message: "You have to confirm your email address before you can do that." }) unless current_seller.email.present?
    return unless current_seller.fetch_or_build_user_compliance_info.country.present?

    compliance_info = current_seller.fetch_or_build_user_compliance_info

    updated_country_code = params.dig(:user, :updated_country_code)
    if updated_country_code.present? && updated_country_code != compliance_info.legal_entity_country_code
      begin
        UpdateUserCountry.new(new_country_code: updated_country_code, user: current_seller).process
        flash[:notice] = "Your country has been updated!"
        return render json: { success: true }
      rescue => e
        Bugsnag.notify("Update country failed for user #{current_seller.id} (from #{compliance_info.country_code} to #{updated_country_code}): #{e}")
        return render json: { success: false, error_message: "Country update failed" }
      end
    end

    if Compliance::Countries::USA.common_name == compliance_info.legal_entity_country
      zip_code = params.dig(:user, :is_business) ? params.dig(:user, :business_zip_code).presence : params.dig(:user, :zip_code).presence
      if zip_code
        return render(json: { success: false, error_message: "You entered a ZIP Code that doesn't exist within your country." }) unless UsZipCodes.identify_state_code(zip_code).present?
      end
    end

    payout_type = if params[:payment_address].present?
      "PayPal"
    elsif params[:card].present?
      "debit card"
    else
      "bank account"
    end

    if params.dig(:user, :country) == Compliance::Countries::ARE.alpha2 && !params.dig(:user, :is_business) && payout_type != "PayPal"
      return render(json: { success: false, error_message: "Individual accounts from the UAE are not supported. Please use a business account." })
    end
    return render(json: { success: false, error_message: "You cannot change your payout method to #{payout_type} because you have a stripe account connected." }) if current_seller.has_stripe_account_connected?

    current_seller.tos_agreements.create!(ip: request.remote_ip)

    return unless update_payout_method

    return unless update_user_compliance_info

    if params[:payout_threshold_cents].present? && params[:payout_threshold_cents] < current_seller.minimum_payout_threshold_cents
      return render json: { success: false, error_message: "Your payout threshold must be greater than the minimum payout amount" }
    end

    unless current_seller.update(
      params.permit(:payouts_paused_by_user, :payout_threshold_cents, :payout_frequency)
    )
      return render json: { success: false, error_message: current_seller.errors.full_messages.first }
    end

    # Once the user has submitted all their information, and a bank account record was created for them,
    # we can create a stripe merchant account for them if they don't already have one.
    if current_seller.active_bank_account && current_seller.merchant_accounts.stripe.alive.empty? && current_seller.native_payouts_supported?
      begin
        StripeMerchantAccountManager.create_account(current_seller, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
      rescue => e
        return render json: { success: false, error_message: e.try(:message) || "Something went wrong." }
      end
    end

    if flash[:notice].blank?
      flash[:notice] = "Thanks! You're all set."
    end

    render json: { success: true }
  end

  def set_country
    compliance_info = current_seller.fetch_or_build_user_compliance_info
    return head :forbidden if compliance_info.country.present?

    compliance_info.dup_and_save! do |new_compliance_info|
      new_compliance_info.country = ISO3166::Country[params[:country]]&.common_name

      new_currency_type = Country.new(new_compliance_info.country_code).default_currency
      if new_currency_type && new_currency_type != current_seller.currency_type
        current_seller.currency_type = new_currency_type
        current_seller.save!
      end
    end
  end

  def opt_in_to_au_backtax_collection
    # Just rudimentary validation on the name here. We want an honest attempt at putting their name, but we don't want a meaningless string of characters.
    if current_seller.alive_user_compliance_info&.legal_entity_name && current_seller.alive_user_compliance_info.legal_entity_name.length != params["signature"].length
      return render json: { success: false, error: "Please enter your exact name." }
    end

    BacktaxAgreement.create!(user: current_seller,
                             jurisdiction: BacktaxAgreement::Jurisdictions::AUSTRALIA,
                             signature: params["signature"])


    render json: { success: true }
  end

  def paypal_connect
    if params[:merchantIdInPayPal].blank? || params[:merchantId].blank? || current_seller.external_id != params[:merchantId].split("-")[0]
      redirect_to settings_payments_path, notice: "There was an error connecting your PayPal account with Gumroad."
      return
    end

    meta = params.slice(:merchantId, :permissionsGranted, :accountStatus, :consentStatus, :productIntentID, :isEmailConfirmed)

    message = PaypalMerchantAccountManager.new.update_merchant_account(
      user: current_seller,
      paypal_merchant_id: params[:merchantIdInPayPal],
      meta:,
      send_email_confirmation_notification: false
    )

    redirect_to settings_payments_path, notice: message
  end

  def remove_credit_card
    if current_seller.remove_credit_card
      head :no_content
    else
      render json: { error: current_seller.errors.full_messages.join(",") }, status: :bad_request
    end
  end

  def remediation
    authorize

    if current_seller.stripe_account.blank? || current_seller.user_compliance_info_requests.requested.blank?
      redirect_to settings_payments_path, notice: "Thanks! You're all set." and return
    end

    redirect_to Stripe::AccountLink.create({
                                             account: current_seller.stripe_account.charge_processor_merchant_id,
                                             refresh_url: remediation_settings_payments_url,
                                             return_url: verify_stripe_remediation_settings_payments_url,
                                             type: "account_onboarding",
                                           }).url, allow_other_host: true
  end

  def verify_stripe_remediation
    safe_redirect_to settings_payments_path and return if current_seller.stripe_account.blank?

    stripe_account = Stripe::Account.retrieve(current_seller.stripe_account.charge_processor_merchant_id)

    if stripe_account["requirements"]["currently_due"].blank? && stripe_account["requirements"]["past_due"].blank?
      # We're marking the pending compliance request as provided on our end here if it is no longer due on Stripe.
      # We'll get a account.updated webhook event and mark these requests as provided there as well,
      # but doing it here instead of waiting on the webhook, so that the respective compliance request notice is removed
      # from the page immediately.
      current_seller.user_compliance_info_requests.requested.each(&:mark_provided!)
      flash[:notice] = "Thanks! You're all set."
    end

    safe_redirect_to settings_payments_path
  end

  private
    def update_payout_method
      result = UpdatePayoutMethod.new(user_params: params, seller: current_seller).process

      return true if result[:success]

      case result[:error]
      when :check_card_information_prompt
        render json: { success: false, error_message: "Please check your card information, we couldn't verify it." }
      when :credit_card_error
        render json: { success: false, error_message: strip_tags(result[:data]) }
      when :bank_account_error
        render json: { success: false, error_message: strip_tags(result[:data]) }
      when :account_number_does_not_match
        render json: { success: false, error_message: "The account numbers do not match." }
      when :provide_valid_email_prompt
        render json: { success: false, error_message: "Please provide a valid email address." }
      when :provide_ascii_only_email_prompt
        render json: { success: false, error_message: "Email address cannot contain non-ASCII characters" }
      when :paypal_payouts_not_supported
        render json: { success: false, error_message: "PayPal payouts are not supported in your country." }
      end

      false
    end

    def update_user_compliance_info
      # Handle both user params and user_compliance_info params for guardian information
      compliance_params_to_use = params[:user_compliance_info].present? ? params[:user_compliance_info] : params[:user]
      
      # Validate guardian information if it's for an under-18 user
      if compliance_params_to_use.present? && has_guardian_params?(compliance_params_to_use)
        validation_result = validate_guardian_params(compliance_params_to_use)
        if validation_result
          render json: { success: false, error_message: validation_result }
          return false
        end
      end
      
      result = UpdateUserComplianceInfo.new(compliance_params: compliance_params_to_use, user: current_seller).process

      if result[:success]
        true
      else
        current_seller.comments.create!(
          author_id: GUMROAD_ADMIN_ID,
          comment_type: :note,
          content: result[:error_message]
        )
        render json: { success: false, error_message: result[:error_message], error_code: result[:error_code] }
        false
      end
    end

    def authorize
      super(current_seller_policy)
    end

    def current_seller_policy
      [:settings, :payments, current_seller]
    end

    def has_guardian_params?(params_hash)
      guardian_fields = %w[
        guardian_first_name guardian_last_name guardian_email guardian_phone
        guardian_street_address guardian_city guardian_state guardian_zip_code 
        guardian_country guardian_dob_year guardian_dob_month guardian_dob_day
        guardian_individual_tax_id guardian_stripe_tos_accepted guardian_stripe_processing_tos_accepted
      ]
      guardian_fields.any? { |field| params_hash[field].present? }
    end

    def validate_guardian_params(params_hash)
      required_fields = %w[
        guardian_first_name guardian_last_name guardian_email guardian_phone
        guardian_street_address guardian_city guardian_state guardian_zip_code 
        guardian_country guardian_dob_year guardian_dob_month guardian_dob_day
      ]

      missing_fields = required_fields.select { |field| params_hash[field].blank? }
      return "Missing required guardian fields: #{missing_fields.join(', ')}" if missing_fields.any?

      # Validate email format
      email = params_hash[:guardian_email]
      unless email =~ URI::MailTo::EMAIL_REGEXP
        return "Guardian email must be a valid email address"
      end

      # Validate date of birth is realistic (guardian should be at least 18 years old)
      year = params_hash[:guardian_dob_year].to_i
      month = params_hash[:guardian_dob_month].to_i  
      day = params_hash[:guardian_dob_day].to_i
      
      if year < 1900 || year > Date.current.year - 18
        return "Guardian must be at least 18 years old"
      end

      # Validate TOS acceptance
      unless params_hash[:guardian_stripe_tos_accepted] == true || params_hash[:guardian_stripe_tos_accepted] == "true"
        return "Guardian must accept the terms of service"
      end

      nil # No validation errors
    end
end
