# frozen_string_literal: true

# Shared selection + per-purchase TaxJar order-transaction logic for US state sales tax.
#
# Both the monthly summary report (CreateUsStatesSalesSummaryReportJob, which now only
# summarizes and does NOT push) and the daily uploader (UploadUsStatesSalesTaxToTaxjarJob,
# which pushes each day's orders to TaxJar) share this class so the purchase selection,
# state-assignment, ZIP resolution, dollar amounts, and retry/rescue behavior stay identical.
class UsStateSalesTaxUploader
  # Groups the taxable US purchase ids created in [starts_at, ends_at] by subdivision code,
  # exactly as the original monthly job did. Raises ArgumentError on an invalid subdivision code.
  def self.grouped_purchase_ids_by_state(subdivision_codes:, starts_at:, ends_at:)
    subdivisions = subdivisions_for(subdivision_codes)

    Purchase.successful
      .not_fully_refunded
      .not_chargedback_or_chargedback_reversed
      .where.not(stripe_transaction_id: nil)
      .where("purchases.created_at BETWEEN ? AND ?", starts_at, ends_at)
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
  end

  def self.subdivisions_for(subdivision_codes)
    subdivision_codes.map do |code|
      Compliance::Countries::USA.subdivisions[code].tap { |value| raise ArgumentError, "Invalid subdivision code" unless value }
    end
  end

  def initialize(taxjar_api: TaxjarApi.new, push_to_taxjar: true)
    @taxjar_api = taxjar_api
    @push_to_taxjar = push_to_taxjar
  end

  # Resolves the purchase's ZIP for the given subdivision, optionally creates the TaxJar order
  # transaction (idempotent — an already-imported order is caught and skipped), and returns the
  # purchase's contribution to the summary totals. Returns nil when the purchase cannot be
  # assigned a ZIP for this subdivision (skipped, exactly as the monthly job skipped it).
  def upload(purchase:, subdivision:)
    zip_code = purchase.zip_code if purchase.zip_code.present? && subdivision.code == UsZipCodes.identify_state_code(purchase.zip_code)
    unless zip_code
      geo_ip = GeoIp.lookup(purchase.ip_address)
      zip_code = geo_ip&.postal_code if subdivision.code == geo_ip&.region_name
    end

    return unless zip_code

    price_cents = purchase.price_cents_net_of_refunds
    shipping_cents = purchase.shipping_cents
    gumroad_tax_cents = purchase.gumroad_tax_cents_net_of_refunds

    if @push_to_taxjar
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

      push_transaction(
        purchase:,
        destination:,
        quantity: purchase.quantity,
        product_tax_code: Link::NATIVE_TYPES_TO_TAX_CODE[purchase.link.native_type],
        amount_dollars:,
        shipping_dollars:,
        sales_tax_dollars:,
        unit_price_dollars:
      )
    end

    {
      gmv_cents: purchase.total_cents_net_of_refunds,
      tax_cents: gumroad_tax_cents
    }
  end

  private
    def push_transaction(purchase:, destination:, quantity:, product_tax_code:, amount_dollars:, shipping_dollars:, sales_tax_dollars:, unit_price_dollars:)
      retries = 0
      begin
        @taxjar_api.create_order_transaction(
          transaction_id: purchase.external_id,
          transaction_date: purchase.created_at.iso8601,
          destination:,
          quantity:,
          product_tax_code:,
          amount_dollars:,
          shipping_dollars:,
          sales_tax_dollars:,
          unit_price_dollars:
        )
      rescue Taxjar::Error::GatewayTimeout, *TaxjarErrors::SERVER => e
        retries += 1
        if retries < 3
          Rails.logger.info("UsStateSalesTaxUploader: TaxJar error for purchase with external ID #{purchase.external_id}. Retry attempt #{retries}/3. #{e.class}: #{e.message}")
          sleep(1)
          retry
        else
          Rails.logger.error("UsStateSalesTaxUploader: TaxJar error for purchase with external ID #{purchase.external_id} after 3 retry attempts. #{e.class}: #{e.message}")
          raise
        end
      rescue Taxjar::Error::UnprocessableEntity => e
        Rails.logger.info("UsStateSalesTaxUploader: Purchase with external ID #{purchase.external_id} was already created as a TaxJar transaction. #{e.class}: #{e.message}")
      rescue Taxjar::Error::BadRequest => e
        ErrorNotifier.notify(e)
        Rails.logger.info("UsStateSalesTaxUploader: Failed to create TaxJar transaction for purchase with external ID #{purchase.external_id}. #{e.class}: #{e.message}")
      end
    end
end
