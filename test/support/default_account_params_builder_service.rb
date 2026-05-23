# frozen_string_literal: true

class DefaultAccountParamsBuilderService
  def initialize(country: "US")
    @country = country
    @default_currency = case country
                        when "CA"
                          Currency::CAD
                        when "US"
                          Currency::USD
                        else
                          raise "Unsupported country"
    end
    @params = {}
  end

  def perform
    build_common_params
    build_individual_address
    build_external_account
    build_ssn_last_4 if @country == "US"
    to_h
  end

  def to_h
    @params.dup
  end

  private
    def build_common_params
      @params.deep_merge!({
                            country: @country,
                            default_currency: @default_currency,
                            type: "custom",
                            business_type: "individual",
                            tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
                            business_profile: {
                              url: "www.gumroad.com",
                              product_description: "Test product",
                              mcc: "5734" # Books, Periodicals, and Newspapers
                            },
                            individual: {
                              verification: {
                                document: {
                                  front: "file_identity_document_success"
                                }
                              },
                              dob: {
                                day: 1,
                                month: 1,
                                year: 1901
                              },
                              first_name: "Chuck",
                              last_name: "Bartowski",
                              phone: "0000000000",
                              id_number: "000000000",
                              email: "me@example.com",
                            },
                            requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
                          })
    end

    def build_individual_address
      address = case @country
                when "CA"
                  {
                    line1: "address_full_match",
                    city: "Toronto",
                    state: "ON",
                    postal_code: "M4C 1T2",
                    country: "CA"
                  }
                when "US"
                  {
                    line1: "address_full_match",
                    city: "San Francisco",
                    state: "CA",
                    postal_code: "94107",
                    country: "US"
                  }
                else
                  raise "Unsupported country"
      end

      @params.deep_merge!(
        individual: {
          address:
        }
      )
    end

    def build_external_account
      bank_account = case @country
                     when "CA"
                       {
                         object: "bank_account",
                         country: "CA",
                         currency: Currency::CAD,
                         routing_number: "11000-000",
                         account_number: "000123456789"
                       }
                     when "US"
                       {
                         object: "bank_account",
                         country: "US",
                         currency: Currency::USD,
                         routing_number: "111000000",
                         account_number: "000123456789"
                       }
                     else
                       raise "Unsupported country"
      end

      @params.deep_merge!(external_account: bank_account)
    end

    def build_ssn_last_4
      @params.deep_merge!(
        individual: {
          ssn_last_4: "0000"
        }
      )
    end
end
