# frozen_string_literal: true

class Purchases::InvoicesController < ApplicationController
  layout "inertia", only: [:new, :confirm]

  before_action :set_purchase, except: [:confirm]
  before_action :set_noindex_header, only: [:new, :confirm]
  before_action :require_email_confirmation, except: [:confirm]
  before_action :set_chargeable, only: [:create, :new]

  def confirm
    render inertia: "Purchases/Invoices/Confirm"
  end

  def confirm_email
    redirect_to new_purchase_invoice_path(@purchase.external_id, email: params[:email]), status: :see_other
  end

  def create
    return redirect_to new_purchase_invoice_path(@purchase.external_id, email: invoice_params[:email]), alert: "Your purchase has not been completed by PayPal yet. Please try again soon." if invoice_params["vat_id"].present? && !@purchase.successful?

    address_fields = invoice_params[:address_fields]
    address_fields[:country] = ISO3166::Country[invoice_params[:address_fields][:country_code]]&.common_name
    business_vat_id = invoice_params[:vat_id] if is_vat_id_valid?(invoice_params[:vat_id])
    invoice_presenter = InvoicePresenter.new(@chargeable, address_fields:, additional_notes: invoice_params[:additional_notes]&.strip, business_vat_id:)

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
      session[invoice_file_url_session_key] = s3_obj.presigned_url(:get, expires_in: SignedUrlHelper::SIGNED_S3_URL_VALID_FOR_MAXIMUM.to_i)
      redirect_to new_purchase_invoice_path(@purchase.external_id, email: invoice_params[:email]), notice: message
    rescue StandardError => e
      Rails.logger.error("Chargeable #{@chargeable.class.name} (#{@chargeable.external_id}) invoice generation failed due to: #{e.inspect}")
      Rails.logger.error(e.message)
      Rails.logger.error(e.backtrace.join("\n"))

      redirect_to new_purchase_invoice_path(@purchase.external_id, email: invoice_params[:email]), alert: "Sorry, something went wrong."
    end
  end

  def new
    set_meta_tag(title: "Generate invoice")

    render inertia: "Purchases/Invoices/New", props: {
      form_data: -> { new_invoice_presenter.invoice_generation_form_data_props },
      form_metadata: -> { new_invoice_presenter.invoice_generation_form_metadata_props },
      invoice_file_url: InertiaRails.optional { session.delete(invoice_file_url_session_key) },
    }
  end

  private
    def invoice_file_url_session_key
      "invoice_file_url_#{@purchase.external_id}"
    end

    def new_invoice_presenter
      @_new_invoice_presenter ||= InvoicePresenter.new(@chargeable)
    end

    def invoice_params
      params.permit(:email, :vat_id, :additional_notes, address_fields: [:full_name, :street_address, :city, :state, :zip_code, :country_code])
    end

    def set_chargeable
      @chargeable = Charge::Chargeable.find_by_purchase_or_charge!(purchase: @purchase)
    end

    def is_vat_id_valid?(raw_vat_id)
      return false unless raw_vat_id.present?
      country_code, state_code = @chargeable.purchase_sales_tax_info&.values_at(:country_code, :state_code) || [nil, nil]
      RegionalVatIdValidationService.new(raw_vat_id, country_code:, state_code:).process
    end

    def require_email_confirmation
      return if ActiveSupport::SecurityUtils.secure_compare(@purchase.email, params[:email].to_s)

      redirect_to confirm_purchase_invoice_path(@purchase.external_id), **(params[:email].blank? ? { warning: "Please enter the purchase's email address to generate the invoice." } : { alert: "Incorrect email address. Please try again." })
    end
end
