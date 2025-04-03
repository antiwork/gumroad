# frozen_string_literal: true

# Usage example for the month of August 2022 in the state of Washington:
#
# CreateUsStateMonthlySalesReportsJob.perform_async("WA", 8, 2022)
class CreateUsStateMonthlySalesReportsJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  attr_reader :taxjar_api

  def perform(subdivision_code, month, year)
    subdivision = Compliance::Countries::USA.subdivisions[subdivision_code].tap { |value| raise ArgumentError, "Invalid subdivision code" unless value }
    raise ArgumentError, "Invalid month" unless month.in?(1..12)
    raise ArgumentError, "Invalid year" unless year.in?(2014..3200)

    @taxjar_api = TaxjarApi.new

    row_headers = [
      "Purchase External ID",
      "Purchase Date",
      "Member State of Consumption",
      "Total Transaction",
      "Price",
      "Tax Collected by Gumroad",
      "Combined Tax Rate",
      "Calculated Tax Amount",
      "Jurisdiction State",
      "Jurisdiction County",
      "Jurisdiction City",
      "State Tax Rate",
      "County Tax Rate",
      "City Tax Rate",
      "Amount not collected by Gumroad",
      "Gumroad Product Type",
      "TaxJar Product Tax Code",
    ]

    purchase_ids = Purchase.successful
      .not_fully_refunded
      .not_chargedback_or_chargedback_reversed
      .where.not(stripe_transaction_id: nil)
      .where("purchases.created_at BETWEEN ? AND ?",
             Date.new(year, month).beginning_of_month.beginning_of_day,
             Date.new(year, month).end_of_month.end_of_day)
      .where("(country = 'United States') OR ((country IS NULL OR country = 'United States') AND ip_country = 'United States')")
      .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])
      .pluck(:id, :zip_code, :ip_address)
      .filter_map do |purchase_attributes|
        zip_code = purchase_attributes.second
        ip_address = purchase_attributes.last
        if zip_code.present?
          if subdivision.code == UsZipCodes.identify_state_code(zip_code)
            purchase_attributes.first
          end
        elsif subdivision.code == GeoIp.lookup(ip_address)&.region_name
          purchase_attributes.first
        end
      end

    begin
      temp_file = Tempfile.new
      temp_file.write(row_headers.to_csv)

      purchase_ids.each do |id|
        purchase = Purchase.find(id)

        zip_code = purchase.zip_code if purchase.zip_code.present? && subdivision.code == UsZipCodes.identify_state_code(purchase.zip_code)
        unless zip_code
          geo_ip = GeoIp.lookup(purchase.ip_address)
          zip_code = geo_ip&.postal_code if subdivision.code == geo_ip&.region_name
        end

        # Discard the sale if we can't determine an in-subdivision zip code.
        # TaxJar needs zip code for destination calculations.
        next unless zip_code

        price_cents = purchase.price_cents_net_of_refunds
        gumroad_tax_cents = purchase.gumroad_tax_cents_net_of_refunds
        total_transaction_cents = purchase.total_cents_net_of_refunds

        if purchase.purchase_taxjar_info.present? && (!gumroad_tax_cents.zero? || (gumroad_tax_cents.zero? && purchase.price_cents.zero?))
          taxjar_info = purchase.purchase_taxjar_info
          combined_tax_rate = taxjar_info.combined_tax_rate
          state_tax_rate = taxjar_info.state_tax_rate
          county_tax_rate = taxjar_info.county_tax_rate
          city_tax_rate = taxjar_info.city_tax_rate
          tax_amount_cents = gumroad_tax_cents
          jurisdiction_state = taxjar_info.jurisdiction_state
          jurisdiction_county = taxjar_info.jurisdiction_county
          jurisdiction_city = taxjar_info.jurisdiction_city
          amount_not_collected_by_gumroad = 0
        else
          taxjar_response_json = fetch_taxjar_info(purchase:, subdivision:, zip_code:, price_cents:)
          next if taxjar_response_json.nil?

          combined_tax_rate = taxjar_response_json["rate"]
          state_tax_rate = taxjar_response_json["breakdown"]["state_tax_rate"]
          county_tax_rate = taxjar_response_json["breakdown"]["county_tax_rate"]
          city_tax_rate = taxjar_response_json["breakdown"]["city_tax_rate"]
          tax_amount_cents = (taxjar_response_json["amount_to_collect"] * 100.0).round
          jurisdiction_state = taxjar_response_json["jurisdictions"]["state"]
          jurisdiction_county = taxjar_response_json["jurisdictions"]["county"]
          jurisdiction_city = taxjar_response_json["jurisdictions"]["city"]
          amount_not_collected_by_gumroad = tax_amount_cents - gumroad_tax_cents
        end

        temp_file.write([
          purchase.external_id,
          purchase.created_at.strftime("%m/%d/%Y"),
          subdivision.name,
          Money.new(total_transaction_cents).format(no_cents_if_whole: false, symbol: false),
          Money.new(price_cents).format(no_cents_if_whole: false, symbol: false),
          Money.new(gumroad_tax_cents).format(no_cents_if_whole: false, symbol: false),
          combined_tax_rate,
          Money.new(tax_amount_cents).format(no_cents_if_whole: false, symbol: false),
          jurisdiction_state,
          jurisdiction_county,
          jurisdiction_city,
          state_tax_rate,
          county_tax_rate,
          city_tax_rate,
          Money.new(amount_not_collected_by_gumroad).format(no_cents_if_whole: false, symbol: false),
          purchase.link.native_type,
          Link::NATIVE_TYPES_TO_TAX_CODE[purchase.link.native_type],
        ].to_csv)

        price_dollars = price_cents / 100.0
        unit_price_dollars = price_dollars / purchase.quantity
        shipping_dollars = purchase.shipping_cents / 100.0
        amount_dollars = price_dollars + shipping_dollars
        sales_tax_dollars = gumroad_tax_cents / 100.0
        destination = {
          country: Compliance::Countries::USA.alpha2,
          state: subdivision.code,
          zip: zip_code
        }

        begin
          taxjar_api.create_order_transaction(transaction_id: purchase.external_id,
                                              transaction_date: purchase.created_at.iso8601,
                                              destination:,
                                              quantity: purchase.quantity,
                                              product_tax_code: Link::NATIVE_TYPES_TO_TAX_CODE[purchase.link.native_type],
                                              amount_dollars:,
                                              shipping_dollars:,
                                              sales_tax_dollars:,
                                              unit_price_dollars:)
        rescue Taxjar::Error::UnprocessableEntity => e
          Rails.logger.info("CreateUSStateSalesReportsJob: Purchase with external ID #{purchase.external_id} was already created as a TaxJar transaction. #{e.class}: #{e.message}")
        rescue Taxjar::Error::BadRequest => e
          Bugsnag.notify(e)
          Rails.logger.info("CreateUSStateSalesReportsJob: Failed to create TaxJar transaction for purchase with external ID #{purchase.external_id}. #{e.class}: #{e.message}")
        end

        temp_file.flush
      end

      temp_file.rewind

      s3_filename = "#{subdivision.name.downcase.tr(" ", "-")}-sales-tax-report-#{year}-#{month}-#{SecureRandom.hex(4)}.csv"
      s3_report_key = "sales-tax/#{subdivision.name.downcase.tr(" ", "-")}/#{s3_filename}"
      s3_object = Aws::S3::Resource.new.bucket(REPORTING_S3_BUCKET).object(s3_report_key)
      s3_object.upload_file(temp_file)
      s3_signed_url = s3_object.presigned_url(:get, expires_in: 1.week.to_i).to_s

      SlackMessageWorker.perform_async("payments", "US Sales Tax Reporting", "#{subdivision.name} reports for #{year}-#{month} are ready:\nGumroad format: #{s3_signed_url}", "green")
    ensure
      temp_file.close
    end
  end

  private
    def fetch_taxjar_info(purchase:, subdivision:, zip_code:, price_cents:)
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
        # NoOp
      end
    end
end
