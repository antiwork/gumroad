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

    def determine_gumroad_tax_labels_and_numbers
      country_name = chargeable.country_or_ip_country
      country_code = Compliance::Countries.find_by_name(country_name)&.alpha2

      if Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.include?(country_code)
        [["VAT Registration Number", GUMROAD_VAT_REGISTRATION_NUMBER]]
      elsif Compliance::Countries::AUS.common_name == country_name
        [["Australian Business Number", GUMROAD_AUSTRALIAN_BUSINESS_NUMBER]]
      elsif Compliance::Countries::CAN.alpha2 == country_code
        [["Canada GST Registration Number", GUMROAD_CANADA_GST_REGISTRATION_NUMBER],
         ["QST Registration Number", GUMROAD_QST_REGISTRATION_NUMBER]]
      elsif Compliance::Countries::NOR.alpha2 == country_code
        [["Norway VAT Registration", GUMROAD_NORWAY_VAT_REGISTRATION]]
      elsif Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.include?(country_code) ||
            Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS.include?(country_code)
        [["VAT Registration Number", GUMROAD_OTHER_TAX_REGISTRATION]]
      end
    end
end
