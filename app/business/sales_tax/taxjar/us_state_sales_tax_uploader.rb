# frozen_string_literal: true

# Shared selection + per-purchase TaxJar order-transaction logic for US state sales tax.
#
# Both the monthly summary report (CreateUsStatesSalesSummaryReportJob, which now only
# summarizes and does NOT push) and the daily uploader (UploadUsStatesSalesTaxToTaxjarJob,
# which pushes each day's orders to TaxJar) share this class so the purchase selection,
# state-assignment, ZIP resolution, dollar amounts, and retry/rescue behavior stay identical.
class UsStateSalesTaxUploader
  # The day we switched refund reporting on. Orders for purchases created on/after this day are
  # pushed with their gross (as-of-purchase) amounts and every refund created on/after this day
  # is pushed to TaxJar as its own refund transaction dated by the refund's date. Refunds
  # created before this day were handled the old way — netted into their purchase's order
  # upload — and stay netted on any re-push, so the same tax is never relieved twice and a
  # re-push reproduces a deterministic number.
  #
  # DEPLOY DEPENDENCY: this date must be STRICTLY AFTER the day the change reaches production
  # (deploy no later than the day before). The daily upload for purchases created on the day
  # before the cutover runs early on the cutover morning; it must run THIS code so it nets
  # only pre-cutover refunds. If the old code ran it, it would net in early-cutover-day
  # refunds that this code also reports as refund transactions — double relief. Bump the date
  # forward if the deploy slips.
  REFUND_REPORTING_CUTOVER = Date.new(2026, 7, 20)

  # Groups the taxable US purchase ids created in [starts_at, ends_at] by subdivision code.
  # Raises ArgumentError on an invalid subdivision code.
  #
  # Pre-cutover purchases keep the historical exclusion of fully refunded purchases (their
  # netted amount would be zero) — but only when every refund happened before the cutover.
  # A pre-cutover purchase whose (full) refund landed on/after the cutover must stay included:
  # its netted amount counts only pre-cutover refunds (see
  # netted_amounts_before_refund_reporting), so it is non-zero, and its post-cutover refund is
  # reported separately by grouped_refund_ids_by_state. Dropping the purchase while still
  # reporting its refund would subtract the refund twice (once by omission of the sale, once
  # by the refund leg). Post-cutover purchases are included even when fully refunded: they
  # upload as gross orders, and their refund transactions are what zero them out — excluding
  # them would leave refund transactions with no order to subtract from.
  def self.grouped_purchase_ids_by_state(subdivision_codes:, starts_at:, ends_at:)
    subdivisions = subdivisions_for(subdivision_codes)

    scope = Purchase.successful
      .not_chargedback_or_chargedback_reversed
      .where.not(stripe_transaction_id: nil)
      .where("purchases.created_at BETWEEN ? AND ?", starts_at, ends_at)
      .where("(country = 'United States') OR ((country IS NULL OR country = 'United States') AND ip_country = 'United States')")
      .where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])
      .where("purchases.created_at >= :cutover
              OR (purchases.stripe_refunded IS NULL OR purchases.stripe_refunded = 0)
              OR EXISTS (
                SELECT 1 FROM refunds
                WHERE refunds.purchase_id = purchases.id
                  AND refunds.created_at >= :cutover
                  AND (refunds.status IS NULL OR refunds.status NOT IN ('failed', 'canceled'))
              )",
             cutover: REFUND_REPORTING_CUTOVER.beginning_of_day)

    group_ids_by_state(scope.pluck(:id, :zip_code, :ip_address), subdivisions)
  end

  # Groups the refund ids created in [starts_at, ends_at] by subdivision code, mirroring the
  # purchase selection above so a refund is only ever reported for a purchase whose order was
  # (or would be) reported: settled purchases, US destination, not charged back. Refunds with a
  # terminal-failure status never returned money to the buyer, so they are excluded. (A refund
  # that flips to a terminal-failure status only after its push day is not reversed in TaxJar —
  # the legacy netted path had the same exposure.)
  #
  # Refunds created before REFUND_REPORTING_CUTOVER are never included — before that day,
  # refunds were handled by netting them into the order upload, not by refund transactions.
  # Every refund created on/after the cutover is included: the deploy dependency on the
  # cutover constant guarantees every netted order upload that runs on/after the cutover
  # morning uses this code's netting rule (net only pre-cutover refunds — see
  # netted_amounts_before_refund_reporting), so no refund in this window can also have been
  # netted into an order. The two legs partition refunds exactly by the cutover instant.
  def self.grouped_refund_ids_by_state(subdivision_codes:, starts_at:, ends_at:)
    subdivisions = subdivisions_for(subdivision_codes)

    rows = Refund.joins(:purchase)
      .merge(Purchase.successful.not_chargedback_or_chargedback_reversed)
      .where.not(purchases: { stripe_transaction_id: nil })
      .where("refunds.created_at BETWEEN ? AND ?", starts_at, ends_at)
      .where("refunds.status IS NULL OR refunds.status NOT IN ('failed', 'canceled')")
      .where("(purchases.country = 'United States') OR ((purchases.country IS NULL OR purchases.country = 'United States') AND purchases.ip_country = 'United States')")
      .where(purchases: { charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids] })
      .where("refunds.created_at >= :cutover", cutover: REFUND_REPORTING_CUTOVER.beginning_of_day)
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
  # Gross vs netted is decided HERE, per purchase, so every caller (the daily job, the monthly
  # job's manual re-push path) is automatically consistent with the refund-transaction guard:
  #
  # - A purchase created on/after REFUND_REPORTING_CUTOVER uploads at its gross (as-of-purchase)
  #   amounts. Its refunds are reported as separate refund transactions, so netting them here
  #   as well would relieve the same tax twice.
  # - A pre-cutover purchase uploads with exactly its pre-cutover refunds netted in — the
  #   precise complement of the refunds the refund leg pushes. Netting "all refunds as of
  #   re-push time" (the old behavior) would double-relieve any post-cutover refund that was
  #   also pushed as a refund transaction.
  def upload(purchase:, subdivision:)
    zip_code = resolve_zip_code(purchase:, subdivision:)
    return unless zip_code

    if gross_purchase?(purchase)
      price_cents = purchase.price_cents
      gumroad_tax_cents = purchase.gumroad_tax_cents
      gmv_cents = purchase.total_transaction_cents
    else
      price_cents, gumroad_tax_cents, gmv_cents = netted_amounts_before_refund_reporting(purchase)
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
      gmv_cents:,
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
      # The full transaction amount refunded (price + tax + shipping), matching the
      # total_transaction_cents basis of the order leg's gmv_cents.
      total_refunded_cents: refund.total_transaction_cents.to_i,
      tax_refunded_cents: refund.gumroad_tax_cents.to_i
    }
  end

  private
    def gross_purchase?(purchase)
      purchase.created_at >= REFUND_REPORTING_CUTOVER.beginning_of_day
    end

    # Net-of-refunds amounts for a pre-cutover purchase, counting exactly the refunds that
    # grouped_refund_ids_by_state will never push as refund transactions: refunds created
    # before the cutover instant. Being the exact complement means a re-push of a pre-cutover
    # day/month is deterministic and never double-relieves a refund that was also pushed as a
    # refund transaction. Amounts are clamped at zero like the legacy net_of_refunds_cents was.
    def netted_amounts_before_refund_reporting(purchase)
      netted_refunds = purchase.refunds.where("refunds.created_at < ?", REFUND_REPORTING_CUTOVER.beginning_of_day)
      refunded_amount_cents = netted_refunds.sum(:amount_cents)
      refunded_tax_cents = netted_refunds.sum(:gumroad_tax_cents)
      refunded_total_cents = netted_refunds.sum(:total_transaction_cents)

      [
        [purchase.price_cents - refunded_amount_cents, 0].max,
        [purchase.gumroad_tax_cents - refunded_tax_cents, 0].max,
        [purchase.total_transaction_cents - refunded_total_cents, 0].max
      ]
    end

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

    # TaxJar keeps order and refund transaction ids in one namespace, and our obfuscated ids
    # are derived only from the numeric row id — so a refund row and a purchase row that happen
    # to share the same numeric id would produce the same id. Since "already created" errors
    # from TaxJar are treated as a safe skip, such a collision would silently drop the refund.
    # Suffixing the refund's id keeps it stable while guaranteeing it can never equal an order's.
    def refund_transaction_id(refund)
      "#{refund.external_id}-refund"
    end

    def push_refund_transaction(refund:, purchase:, destination:, quantity:, product_tax_code:, amount_dollars:, sales_tax_dollars:, unit_price_dollars:)
      transaction_id = refund_transaction_id(refund)
      with_taxjar_error_handling(transaction_id:) do
        @taxjar_api.create_refund_transaction(
          transaction_id:,
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
        # TaxJar returns 422 both for a duplicate transaction id (safe to skip — that's the
        # idempotency path on retries/re-pushes) and for genuinely rejected transactions, e.g.
        # a refund whose transaction_reference_id doesn't exist as an order. Only the duplicate
        # case may be silently skipped; anything else is a dropped transaction and must notify.
        if e.message.to_s.include?(TaxjarApi::TRANSACTION_ALREADY_IMPORTED_ERROR_MESSAGE)
          Rails.logger.info("UsStateSalesTaxUploader: Transaction with ID #{transaction_id} was already created in TaxJar. #{e.class}: #{e.message}")
        else
          ErrorNotifier.notify(e)
          Rails.logger.error("UsStateSalesTaxUploader: TaxJar rejected transaction with ID #{transaction_id}. #{e.class}: #{e.message}")
        end
      rescue Taxjar::Error::BadRequest => e
        ErrorNotifier.notify(e)
        Rails.logger.info("UsStateSalesTaxUploader: Failed to create TaxJar transaction with ID #{transaction_id}. #{e.class}: #{e.message}")
      end
    end
end
