# frozen_string_literal: true

class Purchases::InvoicesController < ApplicationController
  before_action :set_purchase
  before_action :set_noindex_header
  before_action :require_email_confirmation, only: [:new, :create]
  before_action :check_for_successful_purchase_for_vat_refund, only: [:create]

  layout "inertia", only: [:new, :confirm]

  def confirm
    render inertia: "Purchases/Invoices/Confirm", props: {
      invoice_url: generate_invoice_by_buyer_path(params[:id])
    }
  end

  def new
    chargeable = Charge::Chargeable.find_by_purchase_or_charge!(purchase: @purchase)
    invoice_presenter = InvoicePresenter.new(chargeable)
    render inertia: "Purchases/Invoices/New", props: invoice_presenter.invoice_generation_props
  end

  def create
    chargeable = Charge::Chargeable.find_by_purchase_or_charge!(purchase: @purchase)

    address_fields = {
      full_name: params["full_name"],
      street_address: params["street_address"],
      city: params["city"],
      state: params["state"],
      zip_code: params["zip_code"],
      country: ISO3166::Country[params["country_code"]]&.common_name
    }
    additional_notes = params[:additional_notes]&.strip

    business_vat_id = validate_vat_id(params["vat_id"], chargeable)

    invoice_presenter = InvoicePresenter.new(chargeable, address_fields:, additional_notes:, business_vat_id:)

    begin
      chargeable.refund_gumroad_taxes!(refunding_user_id: logged_in_user&.id, note: address_fields.to_json, business_vat_id:) if business_vat_id

      invoice_html = render_to_string(template: "purchases/send_invoice", locals: { invoice_presenter: }, formats: [:pdf], layout: false)
      pdf = PDFKit.new(invoice_html, page_size: "Letter").to_pdf
      s3_obj = chargeable.upload_invoice_pdf(pdf)

      message = +"The invoice will be downloaded automatically."
      if business_vat_id
        message << " " << tax_refund_notice(chargeable)
      end
      file_url = s3_obj.presigned_url(:get, expires_in: SignedUrlHelper::SIGNED_S3_URL_VALID_FOR_MAXIMUM.to_i)
      render json: { success: true, message:, file_location: file_url }
    rescue StandardError => e
      Rails.logger.error("Chargeable #{chargeable.class.name} (#{chargeable.external_id}) invoice generation failed due to: #{e.inspect}")
      Rails.logger.error(e.message)
      Rails.logger.error(e.backtrace.join("\n"))

      render json: { success: false, message: "Sorry, something went wrong." }
    end
  end

  private
    def require_email_confirmation
      return if ActiveSupport::SecurityUtils.secure_compare(@purchase.email, params[:email].to_s)

      if params[:email].blank?
        flash[:warning] = "Please enter the purchase's email address to generate the invoice."
      else
        flash[:alert] = "Incorrect email address. Please try again."
      end

      redirect_to confirm_generate_invoice_path(@purchase.external_id)
    end

    def check_for_successful_purchase_for_vat_refund
      return if params["vat_id"].blank? || @purchase.successful?

      render json: { success: false, message: "Your purchase has not been completed by PayPal yet. Please try again soon." }
    end

    def validate_vat_id(raw_vat_id, chargeable)
      return nil if raw_vat_id.blank?

      sales_tax_info = chargeable.purchase_sales_tax_info
      return nil if sales_tax_info.blank?

      country_code = sales_tax_info.country_code

      case country_code
      when Compliance::Countries::AUS.alpha2
        AbnValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      when Compliance::Countries::SGP.alpha2
        GstValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      when Compliance::Countries::CAN.alpha2
        if sales_tax_info.state_code == QUEBEC
          QstValidationService.new(raw_vat_id).process ? raw_vat_id : nil
        else
          nil
        end
      when Compliance::Countries::NOR.alpha2
        MvaValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      when Compliance::Countries::BHR.alpha2
        TrnValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      when Compliance::Countries::KEN.alpha2
        KraPinValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      when Compliance::Countries::NGA.alpha2
        FirsTinValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      when Compliance::Countries::TZA.alpha2
        TraTinValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      when Compliance::Countries::OMN.alpha2
        OmanVatNumberValidationService.new(raw_vat_id).process ? raw_vat_id : nil
      else
        if Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.include?(country_code) ||
           Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS_WITH_TAX_ID_PRO_VALIDATION.include?(country_code)
          TaxIdValidationService.new(raw_vat_id, country_code).process ? raw_vat_id : nil
        else
          VatValidationService.new(raw_vat_id).process ? raw_vat_id : nil
        end
      end
    end

    def tax_refund_notice(chargeable)
      sales_tax_info = chargeable.purchase_sales_tax_info
      return "VAT has also been refunded." if sales_tax_info.blank?

      country_code = sales_tax_info.country_code

      if Compliance::Countries::GST_APPLICABLE_COUNTRY_CODES.include?(country_code) ||
         Compliance::Countries::IND.alpha2 == country_code
        "GST has also been refunded."
      elsif Compliance::Countries::CAN.alpha2 == country_code
        "QST has also been refunded."
      elsif Compliance::Countries::MYS.alpha2 == country_code
        "Service tax has also been refunded."
      elsif Compliance::Countries::JPN.alpha2 == country_code
        "CT has also been refunded."
      else
        "VAT has also been refunded."
      end
    end
end
