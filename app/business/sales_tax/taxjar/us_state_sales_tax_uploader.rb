# frozen_string_literal: true

# Shared selection + per-purchase TaxJar order-transaction logic for US state sales tax.
#
# Both the monthly summary report (CreateUsStatesSalesSummaryReportJob, which now only
# summarizes and does NOT push) and the daily uploader (UploadUsStatesSalesTaxToTaxjarJob,
# which pushes each day's orders to TaxJar) share this class so the purchase selection,
# state-assignment, ZIP resolution, dollar amounts, and retry/rescue behavior stay identical.
class UsStateSalesTaxUploader
  # The day we switched refund reporting on. From this day forward, order transactions are
  # pushed with their gross (as-of-purchase) amounts and every refund is pushed to TaxJar as
  # its own refund transaction dated by the refund's date. Before this day, orders were pushed
  # with refunds netted in at upload time and refunds were never sent to TaxJar at all — so a
  # refund transaction must never be pushed for a refund that could have been netted into an
  # already-uploaded order, or the same tax would be relieved twice. The guards in the daily
  # job and in grouped_refund_ids_by_state below enforce that boundary.
  REFUND_REPORTING_CUTOVER = Date.new(2026, 7, 16)

  # Groups the taxable US purchase ids created in [starts_at, ends_at] by subdivision code,
  # exactly as the original monthly job did. Raises ArgumentError on an invalid subdivision code.
  #
  # include_fully_refunded: the historical behavior excludes purchases that are fully refunded
  # at query time. With refund transactions being pushed separately (post-cutover), a fully
  # refunded purchase must still be uploaded as a gross order — its refund transaction is what
  # zeroes it out — otherwise the refund would be subtracted from an order that was never added.
  def self.grouped_purchase_ids_by_state(subdivision_codes:, starts_at:, ends_at:, include_fully_refunded: false)
    subdivisions = subdivisions_for(subdivision_codes)

    scope = Purchase.successful
      .not_chargedback_or_chargedback_reversed
      .where.not(stripe_transaction_id: nil)
      .where("purchases.created_at BETWEEN ? AND ?", starts_at, ends_at)
      .where("(country = 'United States') OR ((country IS NULL OR country = 'United States') AND ip_country = 'United States')")
      .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])
    scope = scope.not_fully_refunded unless include_fully_refunded

    group_ids_by_state(scope.pluck(:id, :zip_code, :ip_address), subdivisions)
  end

  # Groups the refund ids created in [starts_at, ends_at] by subdivision code, mirroring the
  # purchase selection above so a refund is only ever reported for a purchase whose order was
  # (or would be) reported: settled purchases, US destination, not charged back. Refunds with a
  # terminal-failure status never returned money to the buyer, so they are excluded.
  #
  # Refunds against purchases created before REFUND_REPORTING_CUTOVER are only included from
  # the day after the cutover: those orders were uploaded with upload-time netting, and a
  # refund created before the netted upload ran (uploads run early the following morning)
  # would already be netted into the order amount.
  def self.grouped_refund_ids_by_state(subdivision_codes:, starts_at:, ends_at:)
    subdivisions = subdivisions_for(subdivision_codes)

    rows = Refund.joins(:purchase)
      .merge(Purchase.successful.not_chargedback_or_chargedback_reversed)
      .where.not(purchases: { stripe_transaction_id: nil })
      .where("refunds.created_at BETWEEN ? AND ?", starts_at, ends_at)
      .where("refunds.status IS NULL OR refunds.status NOT IN ('failed', 'canceled')")
      .where("(purchases.country = 'United States') OR ((purchases.country IS NULL OR purchases.country = 'United States') AND purchases.ip_country = 'United States')")
      .where(purchases: { charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids] })
      .where("purchases.created_at >= :cutover OR refunds.created_at >= :first_safe_refund_day",
             cutover: REFUND_REPORTING_CUTOVER.beginning_of_day,
             first_safe_refund_day: (REFUND_REPORTING_CUTOVER + 1).beginning_of_day)
      .pluck("refunds.id", "purchases.zip_code", "purchases.ip_address")

    group_ids_by_state(rows, subdivisions)
  end

  def self.group_ids_by_state(rows, subdivisions)
    rows.each_with_object({}) do |attributes, result|
      id, zip_code, ip_address = attributes

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
  private_class_method :group_ids_by_state

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
  #
  # gross: when true, the order is reported with its as-of-purchase amounts instead of netting
  # refunds in at upload time. Used by the daily uploader from REFUND_REPORTING_CUTOVER onward,
  # where refunds are reported to TaxJar as their own transactions dated by the refund date —
  # netting them here as well would relieve the same tax twice, and upload-time netting makes
  # a re-push produce different numbers than the original push did.
  def upload(purchase:, subdivision:, gross: false)
    zip_code = resolve_zip_code(purchase:, subdivision:)
    return unless zip_code

    if gross
      price_cents = purchase.price_cents
      gumroad_tax_cents = purchase.gumroad_tax_cents
    else
      price_cents = purchase.price_cents_net_of_refunds
      gumroad_tax_cents = purchase.gumroad_tax_cents_net_of_refunds
    end
    shipping_cents = purchase.shipping_cents

    if @push_to_taxjar
      price_dollars = price_cents / 100.0
      unit_price_dollars = price_dollars / purchase.quantity
      shipping_dollars = shipping_cents / 100.0
      amount_dollars = price_dollars + shipping_dollars
      sales_tax_dollars = gumroad_tax_cents / 100.0

      destination = destination_for(subdivision:, zip_code:)

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
      gmv_cents: gross ? purchase.total_transaction_cents : purchase.total_cents_net_of_refunds,
      tax_cents: gumroad_tax_cents
    }
  end

  # Creates the TaxJar refund transaction for a single refund, dated by the refund's own date so
  # the refunded tax is credited in the period the refund happened (not the purchase's period).
  # ZIP resolution reuses the purchase's, so a refund is skipped in exactly the cases the
  # original order would have been skipped. Amounts come from the refund row itself, so a
  # partial refund is reported at its partial amount and each refund of a multi-refund purchase
  # gets its own transaction.
  def upload_refund(refund:, subdivision:)
    purchase = refund.purchase
    zip_code = resolve_zip_code(purchase:, subdivision:)
    return unless zip_code

    amount_dollars = refund.amount_cents.to_i / 100.0
    sales_tax_dollars = refund.gumroad_tax_cents.to_i / 100.0
    return if amount_dollars.zero? && sales_tax_dollars.zero?

    if @push_to_taxjar
      push_refund_transaction(
        refund:,
        purchase:,
        destination: destination_for(subdivision:, zip_code:),
        quantity: purchase.quantity,
        product_tax_code: Link::NATIVE_TYPES_TO_TAX_CODE[purchase.link.native_type],
        amount_dollars:,
        sales_tax_dollars:,
        unit_price_dollars: amount_dollars / purchase.quantity
      )
    end

    {
      refunded_cents: refund.amount_cents.to_i,
      tax_refunded_cents: refund.gumroad_tax_cents.to_i
    }
  end

  private
    def resolve_zip_code(purchase:, subdivision:)
      if purchase.zip_code.present? && subdivision.code == UsZipCodes.identify_state_code(purchase.zip_code)
        return purchase.zip_code
      end

      geo_ip = GeoIp.lookup(purchase.ip_address)
      geo_ip&.postal_code if subdivision.code == geo_ip&.region_name
    end

    def destination_for(subdivision:, zip_code:)
      {
        country: Compliance::Countries::USA.alpha2,
        state: subdivision.code,
        zip: zip_code
      }
    end

    def push_transaction(purchase:, destination:, quantity:, product_tax_code:, amount_dollars:, shipping_dollars:, sales_tax_dollars:, unit_price_dollars:)
      with_taxjar_error_handling(transaction_id: purchase.external_id) do
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
      end
    end

    def push_refund_transaction(refund:, purchase:, destination:, quantity:, product_tax_code:, amount_dollars:, sales_tax_dollars:, unit_price_dollars:)
      with_taxjar_error_handling(transaction_id: refund.external_id) do
        @taxjar_api.create_refund_transaction(
          transaction_id: refund.external_id,
          transaction_reference_id: purchase.external_id,
          transaction_date: refund.created_at.iso8601,
          destination:,
          quantity:,
          product_tax_code:,
          amount_dollars:,
          sales_tax_dollars:,
          unit_price_dollars:
        )
      end
    end

    def with_taxjar_error_handling(transaction_id:)
      retries = 0
      begin
        yield
      rescue Taxjar::Error::GatewayTimeout, *TaxjarErrors::SERVER => e
        retries += 1
        if retries < 3
          Rails.logger.info("UsStateSalesTaxUploader: TaxJar error for transaction with ID #{transaction_id}. Retry attempt #{retries}/3. #{e.class}: #{e.message}")
          sleep(1)
          retry
        else
          Rails.logger.error("UsStateSalesTaxUploader: TaxJar error for transaction with ID #{transaction_id} after 3 retry attempts. #{e.class}: #{e.message}")
          raise
        end
      rescue Taxjar::Error::UnprocessableEntity => e
        Rails.logger.info("UsStateSalesTaxUploader: Transaction with ID #{transaction_id} was already created in TaxJar. #{e.class}: #{e.message}")
      rescue Taxjar::Error::BadRequest => e
        ErrorNotifier.notify(e)
        Rails.logger.info("UsStateSalesTaxUploader: Failed to create TaxJar transaction with ID #{transaction_id}. #{e.class}: #{e.message}")
      end
    end
end
