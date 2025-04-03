# frozen_string_literal: true

class InvoicePresenter::OrderInfo
  include ActionView::Helpers::TextHelper
  include CurrencyHelper

  attr_reader :charge_info

  def initialize(chargeable, address_fields:, additional_notes:, business_vat_id:)
    @chargeable = chargeable
    @address_fields = address_fields
    @additional_notes = additional_notes
    receipt_presenter = ReceiptPresenter.new(chargeable, for_email: false)
    @payment_info = receipt_presenter.payment_info
    @charge_info  = receipt_presenter.charge_info
    @business_vat_id = business_vat_id
  end

  def heading
    chargeable.is_direct_to_australian_customer? ? "Receipt" : "Invoice"
  end

  def pdf_attributes
    today_price_attributes = payment_info.today_price_attributes
    [
      invoice_date_attribute,
      order_number_attribute,
      address_attribute,
      additional_notes_attribute,
      business_vat_id_attribute,
      business_vat_id_note,
      email_attribute,
      item_purchased_attribute(count: today_price_attributes.size),
      today_price_attributes,
      payment_info.today_shipping_price_attribute,
      non_refunded_tax_price_attributes,
      non_refunded_total_payment_attribute,
      payment_info.payment_method_attribute,
    ].flatten.compact
  end

  def form_attributes
    today_price_attributes = payment_info.today_price_attributes
    [
      business_vat_id_attribute,
      business_vat_id_note,
      email_attribute,
      item_purchased_attribute(count: today_price_attributes.size),
      today_price_attributes,
      payment_info.today_shipping_price_attribute,
      payment_info.today_tax_price_attributes,
      non_refunded_total_payment_attribute,
      payment_info.payment_method_attribute,
    ].flatten.compact
  end

  def invoice_date_attribute
    {
      label: "Date",
      value: charge_info.formatted_created_at,
    }
  end

  def order_number_attribute
    {
      label: "Order number",
      value: chargeable.external_id_numeric_for_invoice,
    }
  end

  def address_attribute
    return if address_fields.values.compact.all?(&:blank?)

    {
      label: "To",
      value: safe_join(
        [
          address_fields[:full_name],
          address_fields[:street_address],
          [address_fields[:city], address_fields[:state], address_fields[:zip_code]].compact.join(", "),
          address_fields[:country]
        ].compact,
        tag.br
      ),
    }
  end

  def additional_notes_attribute
    return if additional_notes.blank?

    {
      label: "Additional notes",
      value: simple_format(additional_notes),
    }
  end

  def business_vat_id_attribute
    @_business_vat_id_attribute ||= begin
      purchase_sales_tax_info = chargeable.purchase_sales_tax_info
      value = business_vat_id || purchase_sales_tax_info&.business_vat_id
      return if value.blank?

      label = \
        if purchase_sales_tax_info&.country_code == Compliance::Countries::ARE.alpha2 || purchase_sales_tax_info&.country_code == Compliance::Countries::BHR.alpha2
          "TRN ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::AUS.alpha2
          "ABN ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::BLR.alpha2
          "UNP ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::CHL.alpha2
          "RUT ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::COL.alpha2
          "NIT ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::CRI.alpha2
          "CPJ ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::ECU.alpha2
          "RUC ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::EGY.alpha2
          "TN ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::GEO.alpha2 ||
              purchase_sales_tax_info&.country_code == Compliance::Countries::KAZ.alpha2 ||
              purchase_sales_tax_info&.country_code == Compliance::Countries::MAR.alpha2 || purchase_sales_tax_info&.country_code == Compliance::Countries::THA.alpha2
          "TIN ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::KOR.alpha2
          "BRN ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::RUS.alpha2
          "INN ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::SRB.alpha2
          "PIB ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::TUR.alpha2
          "VKN ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::UKR.alpha2
          "EDRPOU ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::ISL.alpha2
          "VSK ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::MEX.alpha2
          "RFC ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::MYS.alpha2
          "SST ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::NZL.alpha2
          "IRD ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::JPN.alpha2
          "CN ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::VNM.alpha2
          "CN ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::SGP.alpha2 ||
              purchase_sales_tax_info&.country_code == Compliance::Countries::IND.alpha2
          "GST ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::CAN.alpha2 &&
              purchase_sales_tax_info.state_code == QUEBEC
          "QST ID"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::NOR.alpha2
          "Norway VAT Registration"
        elsif purchase_sales_tax_info&.country_code == Compliance::Countries::VNM.alpha2
          "MST ID"
        else
          "VAT ID"
        end

      {
        label:,
        value:,
      }
    end
  end

  def business_vat_id_note
    return if business_vat_id_attribute.blank?

    value = \
      if Compliance::Countries::GST_APPLICABLE_COUNTRY_CODES.include?(chargeable.purchase_sales_tax_info&.country_code) ||
         Compliance::Countries::IND.alpha2 == chargeable.purchase_sales_tax_info&.country_code
        "Reverse Charge - You are required to account for the GST"
      elsif Compliance::Countries::CAN.alpha2 == chargeable.purchase_sales_tax_info&.country_code &&
            QUEBEC == chargeable.purchase_sales_tax_info&.state_code
        "Reverse Charge - You are required to account for the QST"
      elsif Compliance::Countries::MYS.alpha2 == chargeable.purchase_sales_tax_info&.country_code
        "Reverse Charge - You are required to account for the service tax"
      elsif Compliance::Countries::JPN.alpha2 == chargeable.purchase_sales_tax_info&.country_code
        "Reverse Charge - You are required to account for the CT"
      else
        "Reverse Charge - You are required to account for the VAT"
      end

    {
      label: nil,
      value:,
    }
  end

  private
    attr_reader :additional_notes, :business_vat_id, :chargeable, :address_fields, :payment_info

    def email_attribute
      {
        label: "Email",
        value: chargeable.orderable.email
      }
    end

    def item_purchased_attribute(count:)
      {
        label: "Item purchased".pluralize(count),
        value: nil,
      }
    end

    def non_refunded_total_payment_attribute
      amount_cents = chargeable.successful_purchases.sum do |purchase|
        purchase.is_free_trial_purchase? ? 0 : purchase.non_refunded_total_transaction_amount
      end

      {
        label: "Payment Total",
        value: formatted_dollar_amount(amount_cents),
      }
    end

    def non_refunded_tax_price_attributes
      payment_info.today_tax_price_attributes
    end
end
