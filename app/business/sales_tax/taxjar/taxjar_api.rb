# frozen_string_literal: true

class TaxjarApi
  def initialize
    @client = Taxjar::Client.new(api_key: TAXJAR_API_KEY, headers: { "x-api-version" => "2022-01-24" }, api_url: TAXJAR_ENDPOINT)
    @cache = Redis::Namespace.new(:taxjar_calculations, redis: $redis)
  end

  # Returns nil if there's an error calling TaxJar.
  def calculate_tax_for_order(origin:, destination:, nexus_address:, quantity:, product_tax_code:, unit_price_dollars:, shipping_dollars:)
    taxjar_params = {
      from_country: origin[:country],
      from_state: origin[:state],
      from_zip: origin[:zip],
      to_country: destination[:country],
      to_state: destination[:state],
      to_zip: destination[:zip],
      shipping: shipping_dollars,
      line_items: [
        {
          quantity:,
          unit_price: unit_price_dollars,
          discount: 0,
          product_tax_code:
        }
      ],
      nexus_addresses: [nexus_address]
    }

    with_caching(taxjar_params) do
      @client.tax_for_order(taxjar_params).to_json
    end
  end

  def create_order_transaction(transaction_id:, transaction_date:, destination:, quantity:, product_tax_code:, amount_dollars:, shipping_dollars:, sales_tax_dollars:, unit_price_dollars:)
    taxjar_params = {
      transaction_id: transaction_id,
      transaction_date: transaction_date,
      provider: "api",
      from_country: GumroadAddress::COUNTRY.alpha2,
      from_state: GumroadAddress::STATE,
      from_zip: GumroadAddress::ZIP,
      to_country: destination[:country],
      to_state: destination[:state],
      to_zip: destination[:zip],
      amount: amount_dollars,
      shipping: shipping_dollars,
      sales_tax: sales_tax_dollars,
      line_items: [
        {
          quantity:,
          unit_price: unit_price_dollars,
          sales_tax: sales_tax_dollars,
          product_tax_code:,
        }
      ]
    }

    with_caching(taxjar_params) do
      @client.create_order(taxjar_params).to_json
    end
  end

  private
    def with_caching(taxjar_params)
      cache_key = taxjar_params.to_s
      cached_json = @cache.get(cache_key)

      if cached_json
        JSON.parse(cached_json)
      else
        Rails.logger.info "Making TaxJar Request:: #{taxjar_params.inspect}"
        response_json = yield
        Rails.logger.info "TaxJar Response JSON:: #{response_json}"
        @cache.set(cache_key, response_json, ex: 10.minutes.to_i)
        JSON.parse(response_json)
      end
    rescue *TaxjarErrors::CLIENT => e
      Rails.logger.error "TaxJar Client Error: #{e.inspect}"
      Bugsnag.notify(e)
      raise e
    rescue *TaxjarErrors::SERVER => e
      Rails.logger.error "TaxJar Server Error: #{e.inspect}"
      raise e
    end
end
