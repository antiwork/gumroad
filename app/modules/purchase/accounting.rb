# frozen_string_literal: true

##
# A collection of methods to help with accounting calculations
##

class Purchase
  module Accounting
    # returns price in USD. 0.15 means 15 cents
    def price_dollars
      convert_cents_to_dollars(price_cents)
    end

    def variant_extra_cost_dollars
      convert_cents_to_dollars(variant_extra_cost)
    end

    def tax_dollars
      convert_cents_to_dollars(gumroad_responsible_for_tax? ? gumroad_tax_cents : tax_cents)
    end

    def shipping_dollars
      convert_cents_to_dollars(shipping_cents)
    end

    def fee_dollars
      convert_cents_to_dollars(fee_cents)
    end

    def processor_fee_dollars
      convert_cents_to_dollars(processor_fee_cents)
    end

    def affiliate_credit_dollars
      convert_cents_to_dollars(affiliate_credit_cents)
    end

    # seller's revenue less our fee (assumes we take cut on gross)
    def net_total
      convert_cents_to_dollars(price_cents - fee_cents)
    end

    def sub_total
      convert_cents_to_dollars(price_cents - tax_cents - shipping_cents)
    end

    def amount_refunded_dollars
      convert_cents_to_dollars(amount_refunded_cents)
    end

    private
      # returns US zip code (without +4) only, otherwise nil
      def best_guess_zip
        # trust the user if they provided a zip in a format we understand
        return parsed_zip_from_user_input if parsed_zip_from_user_input

        # only use geoip if we are in the united states
        geo_ip = GeoIp.lookup(ip_address)
        return nil unless geo_ip.try(:country_code) == "US"

        geo_ip.try(:postal_code)
      end

      # returns US zip code from parsing user input (via shipping form), otherwise nil
      # sometimes users will provide a zip+4 or add spaces on either side of zip (or in between zip+4)
      def parsed_zip_from_user_input
        zip_code.scan(/\d{5}/)[0] if zip_code && country == "United States" && zip_code =~ /^\s*\d{5}([\s-]?\d{4})?\s*$/
      end

      def convert_cents_to_dollars(cents)
        (cents.to_f / 100).round(2)
      end
  end
end
