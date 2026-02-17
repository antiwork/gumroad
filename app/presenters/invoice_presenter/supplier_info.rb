# frozen_string_literal: true

class InvoicePresenter::SupplierInfo
  include ActionView::Helpers::TextHelper

  def initialize(chargeable)
    @chargeable = chargeable
    @seller = chargeable.seller
  end

  def heading
    "Supplier"
  end

  def attributes
    gumroad_attributes
  end

  private
    attr_reader :chargeable, :seller

    def gumroad_attributes
      @_gumroad_attributes ||= [
        gumroad_title_attribute,
        gumroad_address_attribute,
        *gumroad_tax_attributes,
        gumroad_email_attribute,
        gumroad_web_attribute,
        gumroad_note_attribute,
      ].compact
    end

    def gumroad_address_attribute
      {
        label: "Office address",
        value: [
          GumroadAddress::STREET,
          "#{GumroadAddress::CITY}, #{GumroadAddress::STATE} #{GumroadAddress::ZIP_PLUS_FOUR}",
          GumroadAddress::COUNTRY.common_name
        ].join("\n")
      }
    end

    def gumroad_title_attribute
      {
        label: nil,
        value: "Gumroad, Inc.",
      }
    end

    def gumroad_tax_attributes
      gumroad_tax_labels_and_numbers = determine_gumroad_tax_labels_and_numbers
      return unless gumroad_tax_labels_and_numbers.present?

      gumroad_tax_labels_and_numbers.map do |label, number|
        {
          label: label,
          value: number,
        }
      end
    end

    def gumroad_email_attribute
      {
        label: "Email",
        value: ApplicationMailer::NOREPLY_EMAIL,
      }
    end

    def gumroad_web_attribute
      {
        label: "Web",
        value: ROOT_DOMAIN,
      }
    end

    def gumroad_note_attribute
      {
        label: nil,
        value: "Products supplied by Gumroad.",
      }
    end

    TAX_REGISTRATIONS_BY_COUNTRY = {
      Compliance::Countries::GBR.alpha2 => [["UK VAT Registration", GUMROAD_UK_VAT_REGISTRATION]],
      Compliance::Countries::AUS.alpha2 => [["Australian Business Number", GUMROAD_AUSTRALIAN_BUSINESS_NUMBER]],
      Compliance::Countries::NOR.alpha2 => [["Norway VAT Registration", GUMROAD_NORWAY_VAT_REGISTRATION]],
      Compliance::Countries::IND.alpha2 => [["GSTIN", GUMROAD_INDIA_GSTIN]],
      Compliance::Countries::JPN.alpha2 => [["JCT Registration Number", GUMROAD_JAPAN_JCT]],
      Compliance::Countries::NZL.alpha2 => [["New Zealand GST", GUMROAD_NEW_ZEALAND_GST]],
      Compliance::Countries::NGA.alpha2 => [["FIRS TIN", GUMROAD_NIGERIA_TIN]],
      Compliance::Countries::SGP.alpha2 => [["Singapore GST", GUMROAD_SINGAPORE_GST]],
      Compliance::Countries::KOR.alpha2 => [["South Korea VAT", GUMROAD_SOUTH_KOREA_VAT]],
      Compliance::Countries::CHE.alpha2 => [["Switzerland VAT", GUMROAD_SWITZERLAND_VAT]],
      Compliance::Countries::THA.alpha2 => [["Thailand VAT", GUMROAD_THAILAND_VAT]],
    }.freeze

    def determine_gumroad_tax_labels_and_numbers
      country_name = chargeable.country_or_ip_country
      country_code = Compliance::Countries.find_by_name(country_name)&.alpha2

      # Check UK first since it has its own VAT number (not the EU OSS number)
      if country_code == Compliance::Countries::GBR.alpha2
        TAX_REGISTRATIONS_BY_COUNTRY[country_code]
      elsif Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.include?(country_code)
        [["VAT Registration Number", GUMROAD_VAT_REGISTRATION_NUMBER]]
      elsif country_code == Compliance::Countries::CAN.alpha2
        canada_tax_labels_and_numbers
      else
        TAX_REGISTRATIONS_BY_COUNTRY[country_code]
      end
    end

    def canada_tax_labels_and_numbers
      state_code = chargeable.purchase_sales_tax_info&.state_code
      result = [["Canada GST Registration Number", GUMROAD_CANADA_GST_REGISTRATION_NUMBER]]
      case state_code
      when QUEBEC
        result << ["QST Registration Number", GUMROAD_QST_REGISTRATION_NUMBER]
      when "BC"
        result << ["BC PST Registration Number", GUMROAD_CANADA_BC_PST]
      when "SK"
        result << ["SK PST Registration Number", GUMROAD_CANADA_SK_PST]
      when "MB"
        result << ["MB RST Registration Number", GUMROAD_CANADA_MB_RST]
      end
      result
    end
end
