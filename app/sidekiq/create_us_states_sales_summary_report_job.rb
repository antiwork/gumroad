# frozen_string_literal: true

class CreateUsStatesSalesSummaryReportJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  attr_reader :taxjar_api

  def perform(subdivision_codes, month, year, push_to_taxjar: true)
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    @taxjar_api = TaxjarApi.new
    @push_to_taxjar = push_to_taxjar
    subdivisions = subdivision_codes.map do |code|
      Compliance::Countries::USA.subdivisions[code].tap { |value| raise ArgumentError, "Invalid subdivision code" unless value }
    end

    row_headers = [
      "State",
      "GMV",
      "Number of orders",
      "Sales tax collected"
    ]

    purchase_ids_by_state = Purchase.successful
      .not_fully_refunded
      .not_chargedback_or_chargedback_reversed
      .where.not(stripe_transaction_id: nil)
      .where("purchases.created_at BETWEEN ? AND ?",
             Date.new(year, month).beginning_of_month.beginning_of_day,
             Date.new(year, month).end_of_month.end_of_day)
      .where("(country = 'United States') OR ((country IS NULL OR country = 'United States') AND ip_country = 'United States')")
      .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])
      .pluck(:id, :zip_code, :ip_address)
      .each_with_object({}) do |purchase_attributes, result|
        id, zip_code, ip_address = purchase_attributes

        subdivisions.each do |subdivision|
          if zip_code.present?
            if subdivision.code == UsZipCodes.identify_state_code(zip_code)
              result[subdivision.code] ||= []
              result[subdivision.code] << id
            end
          elsif subdivision.code == GeoIp.lookup(ip_address)&.region_name
            result[subdivision.code] ||= []
            result[subdivision.code] << id
          end
        end
      end

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers.to_csv)

      purchase_ids_by_state.each do |subdivision_code, purchase_ids|
        next if purchase_ids.empty?

        subdivision = Compliance::Countries::USA.subdivisions[subdivision_code]
        gmv_cents = 0
        order_count = 0
        tax_collected_cents = 0

        purchase_ids.each do |id|
          purchase = Purchase.find(id)

          zip_code = purchase.zip_code if purchase.zip_code.present? && subdivision.code == UsZipCodes.identify_state_code(purchase.zip_code)
          unless zip_code
            geo_ip = GeoIp.lookup(purchase.ip_address)
            zip_code = geo_ip&.postal_code if subdivision.code == geo_ip&.region_name
          end

          next unless zip_code

          price_cents = purchase.price_cents_net_of_refunds
          shipping_cents = purchase.shipping_cents
          gumroad_tax_cents = purchase.gumroad_tax_cents_net_of_refunds

          price_dollars = price_cents / 100.0
          unit_price_dollars = price_dollars / purchase.quantity
          shipping_dollars = shipping_cents / 100.0
          amount_dollars = price_dollars + shipping_dollars
          sales_tax_dollars = gumroad_tax_cents / 100.0

          destination = {
            country: Compliance::Countries::USA.alpha2,
            state: subdivision.code,
            zip: zip_code
          }

          retries = 0
          begin
            if @push_to_taxjar
              taxjar_api.create_order_transaction(transaction_id: purchase.external_id,
                                                  transaction_date: purchase.created_at.iso8601,
                                                  destination:,
                                                  quantity: purchase.quantity,
                                                  product_tax_code: Link::NATIVE_TYPES_TO_TAX_CODE[purchase.link.native_type],
                                                  amount_dollars:,
                                                  shipping_dollars:,
                                                  sales_tax_dollars:,
                                                  unit_price_dollars:)
            end
          rescue Taxjar::Error::GatewayTimeout, Taxjar::Error::InternalServerError => e
            retries += 1
            if retries < 3
              Rails.logger.info("CreateUsStatesSalesSummaryReportJob: TaxJar error for purchase with external ID #{purchase.external_id}. Retry attempt #{retries}/3. #{e.class}: #{e.message}")
              sleep(1)
              retry
            else
              Rails.logger.error("CreateUsStatesSalesSummaryReportJob: TaxJar error for purchase with external ID #{purchase.external_id} after 3 retry attempts. #{e.class}: #{e.message}")
              raise
            end
          rescue Taxjar::Error::UnprocessableEntity => e
            Rails.logger.info("CreateUsStatesSalesSummaryReportJob: Purchase with external ID #{purchase.external_id} was already created as a TaxJar transaction. #{e.class}: #{e.message}")
          rescue Taxjar::Error::BadRequest => e
            Bugsnag.notify(e)
            Rails.logger.info("CreateUsStatesSalesSummaryReportJob: Failed to create TaxJar transaction for purchase with external ID #{purchase.external_id}. #{e.class}: #{e.message}")
          end

          gmv_cents += purchase.total_cents_net_of_refunds
          order_count += 1
          tax_collected_cents += gumroad_tax_cents
        end

        temp_file.write([
          subdivision.name,
          Money.new(gmv_cents).format(no_cents_if_whole: false, symbol: false),
          order_count,
          Money.new(tax_collected_cents).format(no_cents_if_whole: false, symbol: false)
        ].to_csv)

        temp_file.flush
      end

      temp_file.rewind

      s3_filename = "us-states-sales-tax-summary-#{year}-#{month}-#{SecureRandom.hex(4)}.csv"
      s3_report_key = "sales-tax/summary/#{s3_filename}"
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      SlackMessageWorker.perform_async("payments", "US Sales Tax Summary Report", "Multi-state summary report for #{year}-#{month} is ready:\n#{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end

  private
    def fetch_taxjar_info(purchase:, subdivision:, zip_code:, price_cents:)
      return unless @push_to_taxjar

      origin = {
        country: GumroadAddress::COUNTRY.alpha2,
        state: GumroadAddress::STATE,
        zip: GumroadAddress::ZIP
      }

      destination = {
        country: Compliance::Countries::USA.alpha2,
        state: subdivision.code,
        zip: zip_code
      }

      nexus_address = {
        country: Compliance::Countries::USA.alpha2,
        state: subdivision.code
      }

      product_tax_code = Link::NATIVE_TYPES_TO_TAX_CODE[purchase.link.native_type]
      quantity = purchase.quantity
      unit_price_dollars = price_cents / 100.0 / quantity
      shipping_dollars = purchase.shipping_cents / 100.0

      begin
        taxjar_api.calculate_tax_for_order(origin:,
                                           destination:,
                                           nexus_address:,
                                           quantity:,
                                           product_tax_code:,
                                           unit_price_dollars:,
                                           shipping_dollars:)
      rescue Taxjar::Error::NotFound, Taxjar::Error::BadRequest
      end
    end
end
