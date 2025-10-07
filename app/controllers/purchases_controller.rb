# frozen_string_literal: true

class PurchasesController < ApplicationController
  include CurrencyHelper, PreorderHelper, RecommendationType, ValidateRecaptcha, ProcessRefund
  include Order::ResponseHelpers
  SEARCH_RESULTS_PER_PAGE = 100

  PARAM_TO_ATTRIBUTE_MAPPINGS = {
    friend: :friend_actions,
    plugins: :purchaser_plugins,
    vat_id: :business_vat_id,
    is_preorder: :is_preorder_authorization,
    cc_zipcode: :credit_card_zipcode,
    tax_country_election: :sales_tax_country_code_election,
    stripe_setup_intent_id: :processor_setup_intent_id
  }

  PARAMS_TO_REMOVE_IF_BLANK = [:full_name, :email]

  PUBLIC_ACTIONS = %i[
    confirm subscribe unsubscribe send_invoice generate_invoice receipt resend_receipt
    update_subscription charge_preorder confirm_generate_invoice confirm_receipt_email
  ].freeze
  before_action :authenticate_user!, except: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS

  before_action :authenticate_subscription!, only: %i[update_subscription]
  before_action :authenticate_preorder!, only: %i[charge_preorder]
  before_action :validate_purchase_request, only: [:update_subscription, :charge_preorder]
  before_action :set_purchase, only: %i[
    update resend_receipt send_invoice generate_invoice change_can_contact cancel_preorder_by_seller receipt
    revoke_access undo_revoke_access confirm_receipt_email
  ]
  before_action :verify_current_seller_is_seller_for_purchase, only: %i[update change_can_contact cancel_preorder_by_seller]
  before_action :hide_layouts, only: %i[subscribe unsubscribe generate_invoice receipt confirm_receipt_email]
  before_action :check_for_successful_purchase_for_vat_refund, only: [:send_invoice]
  before_action :set_noindex_header, only: [:receipt, :generate_invoice, :confirm_generate_invoice, :confirm_receipt_email]
  before_action :require_email_confirmation, only: [:generate_invoice, :send_invoice]

  def confirm
    ActiveRecord::Base.connection.stick_to_primary!
    @purchase = Purchase.find_by_external_id(params[:id])
    e404 unless @purchase

    error = Purchase::ConfirmService.new(purchase: @purchase, params:).perform

    if error
      render_error(error, purchase: @purchase)
    else
      create_purchase_event(@purchase)
      handle_recommended_purchase(@purchase) if @purchase.was_product_recommended

      render_create_success(@purchase)
    end
  end

  def unsubscribe
    @purchase = Purchase.find_by_secure_external_id(params[:id], scope: "unsubscribe")

    # If the confirmation_text is present, we are here from secure_redirect_controller#create.
    # There's a chance Charge#id is used instead of Purchase#id in the original unsubscribe URL.
    # We need to look up the purchase by Charge#id in that case.
    if params[:confirmation_text].present? && @purchase&.email != params[:confirmation_text]
      @purchase = Purchase.find_by(id: @purchase.charge.id) if @purchase.charge.present?
      if @purchase&.email != params[:confirmation_text]
        Rails.logger.info("[Error unsubscribing buyer] purchase: #{@purchase&.id}, confirmation_text: #{params[:confirmation_text]}")
        return redirect_to(root_path)
      end
    end

    if @purchase.present?
      @purchase.unsubscribe_buyer
      return
    end

    # Fall back to legacy external_id and initiate secure redirect flow
    purchase = Purchase.find_by_external_id(params[:id])
    charge = Charge.find_by_external_id(params[:id])
    e404 if purchase.blank? && charge.blank?

    confirmation_emails = Set.new
    if charge.present? && charge.successful_purchases.any?
      confirmation_emails += charge.successful_purchases.map(&:email)
      unless purchase.present?
        purchase = charge.successful_purchases.last
      end
    end
    confirmation_emails << purchase.email

    if confirmation_emails.any?
      destination_url = unsubscribe_purchase_url(id: purchase.secure_external_id(scope: "unsubscribe", expires_at: 2.days.from_now))

      # Bundle confirmation_text and destination into a single encrypted payload
      secure_payload = {
        destination: destination_url,
        confirmation_texts: confirmation_emails.to_a,
        created_at: Time.current.to_i,
        send_confirmation_text: true
      }
      encrypted_payload = SecureEncryptService.encrypt(secure_payload.to_json)

      message = "Please enter your email address to unsubscribe"
      error_message = "Email address does not match"
      field_name = "Email address"

      redirect_to secure_url_redirect_path(
        encrypted_payload: encrypted_payload,
        message: message,
        field_name: field_name,
        error_message: error_message
      )
      return
    end

    e404
  end

  def subscribe
    (@purchase = Purchase.find_by_external_id(params[:id])) || e404
    Purchase.where(email: @purchase.email, seller_id: @purchase.seller_id, can_contact: false).find_each do |purchase|
      purchase.update!(can_contact: true)
    end
  end

  def charge_preorder
    return render json: { success: true, next: @preorder.link.long_url } if @preorder.state != "authorization_successful"

    card_data_handling_mode = CardParamsHelper.get_card_data_handling_mode(params)
    card_data_handling_error = CardParamsHelper.check_for_errors(params)
    unless card_data_handling_error
      chargeable = CardParamsHelper.build_chargeable(params)
      if chargeable
        card = CreditCard.create(chargeable, card_data_handling_mode, nil)
        @preorder.credit_card = card if card.errors.empty?
        @preorder.save
      end
    end

    purchase_params = {
      card_data_handling_mode:,
      card_data_handling_error:
    }

    purchase = @preorder.charge!(ip_address: request.remote_ip, browser_guid: cookies[:_gumroad_guid], purchase_params:)
    if purchase&.successful?
      @preorder.mark_charge_successful!
      return render json: { success: true, next: @preorder.link.long_url }
    end

    render json: { success: false, error_message: PurchaseErrorCode.customer_error_message(card_data_handling_error&.error_message) }
  end

  def update_subscription
    # TODO (helen): Remove after debugging https://gumroad.slack.com/archives/C01DBV0A257/p1662042866645759
    Rails.logger.info("purchases#update_subscription - id: #{@subscription.external_id} ; params: #{permitted_subscription_params}")
    result =
      Subscription::UpdaterService.new(subscription: @subscription,
                                       gumroad_guid: cookies[:_gumroad_guid],
                                       params: permitted_subscription_params,
                                       logged_in_user:,
                                       remote_ip: request.remote_ip).perform

    render json: result
  end

  def search
    authorize [:audience, Purchase], :index?

    per_page = SEARCH_RESULTS_PER_PAGE
    page = (params[:page] || 1).to_i
    offset = (page - 1) * per_page
    query = params[:query].to_s.strip

    search_options = {
      seller: current_seller,
      seller_query: query,
      state: Purchase::ALL_SUCCESS_STATES,
      exclude_non_original_subscription_purchases: true,
      exclude_commission_completion_purchases: true,
      from: (page - 1) * per_page,
      size: per_page,
      sort: [:_score, { created_at: :desc }, { id: :desc }]
    }
    purchases_records = PurchaseSearchService.search(search_options).records.load

    imported_customers_records = current_seller.imported_customers.alive.
      where("email LIKE ?", "%#{query}%").
      order(id: :desc).limit(per_page).offset(offset).
      load

    result = purchases_records + imported_customers_records

    can_ping = current_seller.urls_for_ping_notification(ResourceSubscription::SALE_RESOURCE_NAME).size > 0

    render json: result.as_json(include_receipt_url: true, include_ping: { value: can_ping }, version: 2, include_variant_details: true, query:, pundit_user:)
  end

  def update
    authorize [:audience, @purchase]

    @purchase.email = params[:email].strip if params[:email].present?
    @purchase.full_name = params[:full_name] if params[:full_name].present?
    @purchase.street_address = params[:street_address] if params[:street_address].present?
    @purchase.city = params[:city] if params[:city].present?
    @purchase.state = params[:state] if params[:state].present?
    @purchase.zip_code = params[:zip_code] if params[:zip_code].present?
    @purchase.country = Compliance::Countries.find_by_name(params[:country])&.common_name if params[:country].present?
    @purchase.quantity = params[:quantity] if @purchase.is_multiseat_license? && params[:quantity].to_i > 0
    @purchase.save

    if params[:email].present? && @purchase.is_bundle_purchase?
      @purchase.product_purchases.each { _1.update!(email: params[:email]) }
    end

    if params[:giftee_email] && @purchase.gift
      giftee_purchase = @purchase.gift.giftee_purchase
      gift = @purchase.gift

      gift.giftee_email = params[:giftee_email]
      gift.save!

      giftee_purchase.email = params[:giftee_email]
      giftee_purchase.save!

      giftee_purchase.resend_receipt
    end

    if @purchase.errors.empty?
      render json: { success: true, purchase: @purchase.as_json(pundit_user:) }
    else
      render json: { success: false }
    end
  end

  def refund
    authorize [:audience, Purchase]
    process_refund(seller: current_seller, user: logged_in_user, purchase_external_id: params[:id], amount: params[:amount], impersonating: impersonating?)
  end

  def revoke_access
    authorize [:audience, @purchase]

    @purchase.update!(is_access_revoked: true)
    head :no_content
  end

  def undo_revoke_access
    authorize [:audience, @purchase]

    @purchase.update!(is_access_revoked: false)
    head :no_content
  end

  def resend_receipt
    @purchase.resend_receipt
    head :no_content
  end

  def confirm_generate_invoice
    @react_component_props = { invoice_url: generate_invoice_by_buyer_path(params[:id]) }
  end

  def generate_invoice
    chargeable = Charge::Chargeable.find_by_purchase_or_charge!(purchase: @purchase)
    @invoice_presenter = InvoicePresenter.new(chargeable)
    @title = "Generate invoice"
  end

  def send_invoice
    @chargeable = Charge::Chargeable.find_by_purchase_or_charge!(purchase: @purchase)

    address_fields = {
      full_name: params["full_name"],
      street_address: params["street_address"],
      city: params["city"],
      state: params["state"],
      zip_code: params["zip_code"],
      country: ISO3166::Country[params["country_code"]]&.common_name
    }
    additional_notes = params[:additional_notes]&.strip

    raw_vat_id = params["vat_id"].present? ? params["vat_id"] : nil
    if raw_vat_id
      if @chargeable.purchase_sales_tax_info.present? &&
         @chargeable.purchase_sales_tax_info.country_code == Compliance::Countries::AUS.alpha2
        business_vat_id = AbnValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      elsif @chargeable.purchase_sales_tax_info.present? &&
            @chargeable.purchase_sales_tax_info.country_code == Compliance::Countries::SGP.alpha2
        business_vat_id = GstValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      elsif @chargeable.purchase_sales_tax_info.present? &&
            @chargeable.purchase_sales_tax_info.country_code == Compliance::Countries::CAN.alpha2 &&
            @chargeable.purchase_sales_tax_info.state_code == QUEBEC
        business_vat_id = QstValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      elsif @chargeable.purchase_sales_tax_info.present? &&
            @chargeable.purchase_sales_tax_info.country_code == Compliance::Countries::NOR.alpha2
        business_vat_id = MvaValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      elsif @chargeable.purchase_sales_tax_info.present? &&
            @chargeable.purchase_sales_tax_info.country_code == Compliance::Countries::BHR.alpha2
        business_vat_id = TrnValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      elsif @chargeable.purchase_sales_tax_info.present? &&
            @chargeable.purchase_sales_tax_info.country_code == Compliance::Countries::KEN.alpha2
        business_vat_id = KraPinValidationService.new(raw_vat_id).process ? raw_vat_id : nil

      elsif @chargeable.purchase_sales_tax_info.present? &&
            @chargeable.purchase_sales_tax_info.country_code == Compliance::Countries::NGA.alpha2
        business_vat_id = FirsTinValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      elsif @chargeable.purchase_sales_tax_info.present? &&
            @chargeable.purchase_sales_tax_info.country_code == Compliance::Countries::TZA.alpha2
        business_vat_id = TraTinValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      elsif @chargeable.purchase_sales_tax_info.present? &&
            @chargeable.purchase_sales_tax_info.country_code == Compliance::Countries::OMN.alpha2
        business_vat_id = OmanVatNumberValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      elsif @chargeable.purchase_sales_tax_info.present? &&
            (Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.include?(@chargeable.purchase_sales_tax_info.country_code) ||
            Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS_WITH_TAX_ID_PRO_VALIDATION.include?(@chargeable.purchase_sales_tax_info.country_code))
        business_vat_id = TaxIdValidationService.new(raw_vat_id, @chargeable.purchase_sales_tax_info.country_code).process ? raw_vat_id : nil
      else
        business_vat_id = VatValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      end
    end

    invoice_presenter = InvoicePresenter.new(@chargeable, address_fields:, additional_notes:, business_vat_id:)

    begin
      @chargeable.refund_gumroad_taxes!(refunding_user_id: logged_in_user&.id, note: address_fields.to_json, business_vat_id:) if business_vat_id

      invoice_html = render_to_string(locals: { invoice_presenter: }, formats: [:pdf], layout: false)
      pdf = PDFKit.new(invoice_html, page_size: "Letter").to_pdf
      s3_obj = @chargeable.upload_invoice_pdf(pdf)

      message = +"The invoice will be downloaded automatically."
      if business_vat_id
        notice =
          if @chargeable.purchase_sales_tax_info.present? &&
             (Compliance::Countries::GST_APPLICABLE_COUNTRY_CODES.include?(@chargeable.purchase_sales_tax_info.country_code) ||
             Compliance::Countries::IND.alpha2 == @chargeable.purchase_sales_tax_info.country_code)
            "GST has also been refunded."
          elsif @chargeable.purchase_sales_tax_info.present? &&
                Compliance::Countries::CAN.alpha2 == @chargeable.purchase_sales_tax_info.country_code
            "QST has also been refunded."
          elsif @chargeable.purchase_sales_tax_info.present? &&
            Compliance::Countries::MYS.alpha2 == @chargeable.purchase_sales_tax_info.country_code
            "Service tax has also been refunded."
          elsif @chargeable.purchase_sales_tax_info.present? &&
            Compliance::Countries::JPN.alpha2 == @chargeable.purchase_sales_tax_info.country_code
            "CT has also been refunded."
          else
            "VAT has also been refunded."
          end
        message << " " << notice
      end
      file_url = s3_obj.presigned_url(:get, expires_in: SignedUrlHelper::SIGNED_S3_URL_VALID_FOR_MAXIMUM.to_i)
      render json: { success: true, message:, file_location: file_url }
    rescue StandardError => e
      Rails.logger.error("Chargeable #{@chargeable.class.name} (#{@chargeable.external_id}) invoice generation failed due to: #{e.inspect}")
      Rails.logger.error(e.message)
      Rails.logger.error(e.backtrace.join("\n"))

      render json: { success: false, message: "Sorry, something went wrong." }
    end
  end

  def change_can_contact
    authorize [:audience, @purchase]

    @purchase.can_contact = ActiveModel::Type::Boolean.new.cast(params[:can_contact])
    @purchase.save!

    head :no_content
  end

  def cancel_preorder_by_seller
    authorize [:audience, @purchase]

    if @purchase.preorder.mark_cancelled
      render json: { success: true }
    else
      render json: { success: false }
    end
  end

  def confirm_receipt_email
    @title = "Confirm Email"
    @hide_layouts = true
  end

  def receipt
    if (@purchase.purchaser && @purchase.purchaser == logged_in_user) ||
       (logged_in_user && logged_in_user.is_team_member?) ||
       (params[:email].present? && ActiveSupport::SecurityUtils.secure_compare(@purchase.email.downcase, params[:email].to_s.strip.downcase))
      message = CustomerMailer.receipt(@purchase.id, for_email: false)
      # Generate the same markup used in the email
      Premailer::Rails::Hook.perform(message)

      render html: message.html_part.body.raw_source.html_safe, layout: false
    else
      if params[:email].present?
        flash[:alert] = "Wrong email. Please try again."
      end
      redirect_to confirm_receipt_email_purchase_path(@purchase.external_id)
    end
  end

  def export
    authorize [:audience, Purchase], :index?

    tempfile = Exports::PurchaseExportService.export(
      seller: current_seller,
      recipient: impersonating_user || logged_in_user,
      filters: params.slice(:start_time, :end_time, :product_ids, :variant_ids),
    )

    if tempfile
      send_file tempfile.path
    else
      flash[:warning] = "You will receive an email in your inbox with the data you've requested shortly."
      redirect_back(fallback_location: customers_path)
    end
  end

  protected
    def verify_current_seller_is_seller_for_purchase
      e404_json if @purchase.nil? || @purchase.seller != current_seller
    end

    def validate_purchase_request
      # Don't allow the purchase to go through if the buyer is a bot. Pretend that the purchase succeeded instead.
      return render json: { success: true } if is_bot?

      # Don't allow the purchase to go through if cookies are disabled and it's a paid purchase
      contains_paid_purchase = if params[:line_items].present?
        params[:line_items].any? { |product_params| product_params[:perceived_price_cents] != "0" }
      else
        params[:perceived_price_cents] != "0"
      end
      browser_guid = cookies[:_gumroad_guid]
      return render_error("Cookies are not enabled on your browser. Please enable cookies and refresh this page before continuing.") if contains_paid_purchase && browser_guid.blank?

      # Verify reCAPTCHA response
      unless skip_recaptcha?
        render_error("Sorry, we could not verify the CAPTCHA. Please try again.") unless valid_recaptcha_response_and_hostname?(site_key: GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY"))
      end
    end

    def render_create_success(purchase)
      render json: purchase.purchase_response
    end

    def render_error(error_message, purchase: nil)
      render json: error_response(error_message, purchase:)
    end

    def handle_recommended_purchase(purchase)
      return unless purchase.successful? || purchase.preorder_authorization_successful? || purchase.is_free_trial_purchase?

      if RecommendationType.is_product_recommendation?(purchase.recommended_by)
        recommendation_type = RecommendationType::PRODUCT_RECOMMENDATION
        recommended_by_link = Link.find_by(unique_permalink: purchase.recommended_by)
      else
        recommendation_type = purchase.recommended_by
        recommended_by_link = nil
      end

      purchase_info_params = {
        purchase:,
        recommended_link: purchase.link,
        recommended_by_link:,
        recommendation_type:,
        recommender_model_name: purchase.recommender_model_name,
      }

      if purchase.was_discover_fee_charged?
        purchase_info_params[:discover_fee_per_thousand] = purchase.link.discover_fee_per_thousand
      end

      RecommendedPurchaseInfo.create!(purchase_info_params)
    end

    def permitted_subscription_params
      params.except("g-recaptcha-response").permit(:id, :price_id, :card_data_handling_mode, :card_country, :card_country_source,
                                                   :stripe_payment_method_id, :stripe_customer_id, :stripe_setup_intent_id, :paymentToken, :billing_agreement_id, :visual,
                                                   :braintree_device_data, :braintree_transient_customer_store_key, :use_existing_card,
                                                   :price_range, :perceived_price_cents, :perceived_upgrade_price_cents, :quantity,
                                                   :declined, stripe_error: {}, variants: [], contact_info: [:email, :full_name,
                                                                                                             :street_address, :city, :state, :zip_code, :country]).to_h
    end

    def hide_layouts
      @body_id = "app"
      @on_purchases_page = @hide_layouts = true
    end

    def authenticate_subscription!
      @subscription = Subscription.find_by_external_id!(params[:id])
      e404 unless cookies.encrypted[@subscription.cookie_key] == @subscription.external_id
    end

    def authenticate_preorder!
      @preorder = Preorder.find_by_external_id(params[:id])
      e404 if @preorder.blank?
    end

    def check_for_successful_purchase_for_vat_refund
      return if params["vat_id"].blank? || @purchase.successful?

      render json: { success: false, message: "Your purchase has not been completed by PayPal yet. Please try again soon." }
    end

    def skip_recaptcha?
      site_key = GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY")

      return true if (Rails.env.development? || Rails.env.test?) && site_key.blank?
      return true if action_name == "update_subscription" && params[:perceived_upgrade_price_cents].to_s == "0"
      return true if action_name.in?(["update_subscription", "charge_preorder"]) && params[:use_existing_card]
      return true if valid_wallet_payment?

      false
    end

    def valid_wallet_payment?
      return false if [params[:wallet_type], params[:stripe_payment_method_id]].any?(&:blank?)
      payment_method = Stripe::PaymentMethod.retrieve(
        params[:stripe_payment_method_id]
      )
      payment_method&.card&.wallet&.type == params[:wallet_type]
    rescue Stripe::StripeError
      render_error("Sorry, something went wrong.")
    end

    def require_email_confirmation
      return if ActiveSupport::SecurityUtils.secure_compare(@purchase.email, params[:email].to_s)

      if params[:email].blank?
        flash[:warning] = "Please enter the purchase's email address to generate the invoice."
      else
        flash[:alert] = "Incorrect email address. Please try again."
      end

      redirect_to confirm_generate_invoice_path(@purchase.external_id)
    end
end
