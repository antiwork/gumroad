# frozen_string_literal: true

class Exports::PurchaseExportService
  PURCHASE_FIELDS = [
    "Purchase ID", "Item Name", "Buyer Name", "Purchase Email", "Buyer Email", "Do not contact?",
    "Purchase Date", "Purchase Time (UTC timezone)", "Subtotal ($)", "Taxes ($)", "Tax Type", "Shipping ($)",
    "Sale Price ($)", "Fees ($)", "Net Total ($)", "Tip ($)", "Tax Included in Price?",
    "Street Address", "City", "Zip Code", "State", "Country", "Referrer", "Refunded?",
    "Partial Refund ($)", "Fully Refunded?", "Disputed?", "Dispute Won?", "Access Revoked?", "Variants",
    "Discount Code", "Recurring Charge?", "Free trial purchase?", "Pre-order authorization?", "Product ID", "Order Number",
    "Pre-order authorization time (UTC timezone)", "Custom Fields", "Item Price ($)",
    "Variants Price ($)", "Giftee Email", "SKU ID", "Quantity", "Recurrence",
    "Affiliate", "Affiliate commission ($)", "Discover?", "Subscription End Date", "Rating", "Review",
    "License Key", "License Key Activation Count", "License Key Enabled?", "Payment Type", "PayPal Transaction ID", "PayPal Fee Amount", "PayPal Fee Currency",
    "Stripe Transaction ID", "Stripe Fee Amount", "Stripe Fee Currency",
    "Purchasing Power Parity Discounted?", "Upsold?", "Sent Abandoned Cart Email?",
    "UTM Source", "UTM Medium", "UTM Campaign", "UTM Term", "UTM Content"
  ].freeze
  TOTALS_COLUMN_NAME = "Totals"
  TOTALS_FIELDS = [
    "Subtotal ($)", "Taxes ($)", "Shipping ($)", "Sale Price ($)", "Fees ($)", "Net Total ($)",
    "Tip ($)", "Partial Refund ($)", "Variants Price ($)", "Item Price ($)", "Affiliate commission ($)",
    "PayPal Fee Amount", "Stripe Fee Amount"
  ].freeze
  SYNCHRONOUS_EXPORT_THRESHOLD = 2_000

  def initialize(purchases)
    @purchases = purchases
  end

  def custom_fields
    @_custom_fields ||= @purchases.includes(:purchase_custom_fields, link: :custom_fields).find_each.flat_map do |purchase|
      [
        purchase.custom_fields.pluck(:name),
        purchase.link.custom_fields.map { |product_custom_field| product_custom_field["name"] }
      ].flatten
    end.uniq
  end

  def purchases_data
    gift_includes = {
      giftee_purchase: [
        :link, :product_review, :license,
        subscription: { true_original_purchase: :product_review, original_purchase: :license }
      ]
    }
    purchases_with_includes = @purchases.includes(
      :link, :variant_attributes, :license, :purchaser, :offer_code, :product_review, :purchase_custom_fields, :upsell_purchase, :merchant_account,
      subscription: [{ true_original_purchase: :product_review }],
      order: { cart: { sent_abandoned_cart_emails: :installment } },
      gift_received: gift_includes,
      gift_given: gift_includes,
      utm_link: [target_resource: [:seller, :user]],
    )
    purchases_with_includes.find_each.map do |purchase|
      purchase_data(purchase)
    end
  end

  def perform
    self.class.compile(custom_fields, purchases_data)
  end

  def self.compile(custom_fields, purchases_data_enumerator)
    fields = PURCHASE_FIELDS + custom_fields
    tempfile = Tempfile.new(["Sales", ".csv"], "tmp", encoding: "UTF-8")
    totals = Hash.new(0)

    CsvSafe.open(tempfile, "wb") do |csv|
      csv << fields
      purchases_data_enumerator.each do |(purchase_fields_data, custom_fields_data)|
        row = Array.new(fields.size)
        purchase_fields_data.each do |column_name, value|
          row[fields.index(column_name)] = value
          totals[column_name] += value.to_f if TOTALS_FIELDS.include?(column_name)
        end
        custom_fields_data.each do |column_name, value|
          row[fields.rindex(column_name)] = value
        end
        csv << row
      end

      totals_row = Array.new(fields.size)
      totals_row[0] = TOTALS_COLUMN_NAME
      totals.each do |column_name, value|
        totals_row[fields.index(column_name)] = value.round(2)
      end
      csv << totals_row
    end

    tempfile
  end

  def self.export(seller:, recipient:, filters: {})
    product_ids = Link.by_external_ids(filters[:product_ids]).ids if filters[:product_ids].present?
    variant_ids = BaseVariant.by_external_ids(filters[:variant_ids]).ids if filters[:variant_ids].present?
    start_time = Date.parse(filters[:start_time]).in_time_zone(seller.timezone).beginning_of_day if filters[:start_time].present?
    end_time = Date.parse(filters[:end_time]).in_time_zone(seller.timezone).end_of_day if filters[:end_time].present?

    search_service = PurchaseSearchService.new(
      seller:,
      state: Purchase::NON_GIFT_SUCCESS_STATES,
      exclude_not_charged_non_free_trial_purchases: true,
      exclude_bundle_product_purchases: true,
      any_products_or_variants: { products: product_ids, variants: variant_ids },
      created_on_or_after: start_time,
      created_before: end_time,
      size: SYNCHRONOUS_EXPORT_THRESHOLD
    )
    count = EsClient.count(index: Purchase.index_name, body: { query: search_service.query })["count"]

    if count <= SYNCHRONOUS_EXPORT_THRESHOLD
      records = Purchase.where(id: search_service.process.results.map(&:id))
      Exports::PurchaseExportService.new(records).perform
    else
      export = SalesExport.create!(recipient:, query: search_service.query.deep_stringify_keys)
      Exports::Sales::CreateAndEnqueueChunksWorker.perform_async(export.id)
      false
    end
  end

  private
    def purchase_data(purchase)
      variants_price_dollars = purchase.variant_extra_cost_dollars
      main_or_giftee_purchase = (purchase.is_gift_sender_purchase? ? purchase.gift_given.giftee_purchase : purchase)
      custom_fields_data = purchase.custom_fields.pluck(:name, :value).to_h
      utm_link = purchase.utm_link

      data = {
        "Purchase ID" => purchase.external_id,
        "Item Name" => purchase.link.name,
        "Buyer Name" => purchase.full_name.presence || purchase.purchaser&.name,
        "Purchase Email" => purchase.email,
        "Buyer Email" => purchase.purchaser.try(:email),
        "Do not contact?" => purchase.can_contact? ? 0 : 1,
        "Purchase Date" => purchase.created_at.to_date.to_s,
        "Purchase Time (UTC timezone)" => purchase.created_at.to_time.to_s,
        "Subtotal ($)" => purchase.sub_total,
        "Taxes ($)" => purchase.tax_dollars,
        "Tax Type" => purchase.has_tax_label? ? purchase.tax_label(include_tax_rate: false) : "",
        "Shipping ($)" => purchase.shipping_dollars,
        "Sale Price ($)" => purchase.price_dollars,
        "Fees ($)" => purchase.fee_dollars,
        "Tip ($)" => (purchase.tip&.value_usd_cents || 0) / 100.0,
        "Net Total ($)" => purchase.net_total,
        "Tax Included in Price?" => determine_exclusive_tax_report_field(purchase),
        "Street Address" => pseudo_transliterate(purchase.street_address),
        "City" => pseudo_transliterate(purchase.city),
        "Zip Code" => purchase.zip_code && purchase.zip_code.to_s.rjust(5, "0"),
        "State" => pseudo_transliterate(purchase.state_or_from_ip_address),
        "Country" => pseudo_transliterate(purchase.country_or_from_ip_address),
        "Referrer" => purchase.referrer,
        "Refunded?" => (purchase.stripe_refunded || purchase.stripe_partially_refunded) ? 1 : 0,
        "Partial Refund ($)" => purchase.stripe_partially_refunded ? purchase.amount_refunded_dollars : 0.0,
        "Fully Refunded?" => purchase.stripe_refunded ? 1 : 0,
        "Disputed?" => purchase.chargeback_date ? 1 : 0,
        "Dispute Won?" => purchase.chargeback_reversed? ? 1 : 0,
        "Access Revoked?" => purchase.is_access_revoked ? 1 : 0,
        "Variants" => purchase.variants_list,
        "Discount Code" => purchase.offer_code&.code,
        "Recurring Charge?" => purchase.is_recurring_subscription_charge ? 1 : 0,
        "Free trial purchase?" => purchase.is_free_trial_purchase? ? 1 : 0,
        "Pre-order authorization?" => purchase.is_preorder_authorization? ? 1 : 0,
        "Product ID" => purchase.link.unique_permalink,
        "Order Number" => purchase.external_id_numeric,
        "Pre-order authorization time (UTC timezone)" => (purchase.preorder.created_at.to_time.to_s if purchase.is_preorder_charge?),
        "Custom Fields" => custom_fields_data.to_s,
        "Item Price ($)" => purchase.price_dollars - variants_price_dollars,
        "Variants Price ($)" => variants_price_dollars,
        "Giftee Email" => purchase.giftee_email.presence,
        "SKU ID" => purchase.sku&.custom_name_or_external_id,
        "Quantity" => purchase.quantity,
        "Recurrence" => purchase.subscription&.price&.recurrence,
        "Affiliate" => purchase.affiliate&.affiliate_user&.form_email,
        "Affiliate commission ($)" => (purchase.affiliate_credit_dollars if purchase.affiliate_credit_cents.present?),
        "Discover?" => purchase.was_product_recommended? ? 1 : 0,
        "Subscription End Date" => purchase.subscription&.termination_date&.to_s,
        "Rating" => main_or_giftee_purchase&.original_product_review&.rating,
        "Review" => main_or_giftee_purchase&.original_product_review&.message,
        "License Key" => main_or_giftee_purchase&.license_key,
        "License Key Activation Count" => main_or_giftee_purchase&.license&.uses,
        "License Key Enabled?" => main_or_giftee_purchase&.license&.then { |l| l.disabled? ? 0 : 1 },
        "Payment Type" => ((purchase.card_type == "paypal" ? "PayPal" : "Card") if purchase.card_type.present?),
        "PayPal Transaction ID" => (purchase.stripe_transaction_id if purchase.paypal_order_id?),
        "PayPal Fee Amount" => (purchase.processor_fee_dollars if purchase.paypal_order_id?),
        "PayPal Fee Currency" => (purchase.processor_fee_cents_currency if purchase.paypal_order_id?),
        "Stripe Transaction ID" => (purchase.stripe_transaction_id if purchase.charged_using_stripe_connect_account?),
        "Stripe Fee Amount" => (purchase.processor_fee_dollars if purchase.charged_using_stripe_connect_account?),
        "Stripe Fee Currency" => (purchase.processor_fee_cents_currency if purchase.charged_using_stripe_connect_account?),
        "Purchasing Power Parity Discounted?" => purchase.is_purchasing_power_parity_discounted ? 1 : 0,
        "Upsold?" => purchase.upsell_purchase.present? ? 1 : 0,
        "Sent Abandoned Cart Email?" => sent_abandoned_cart_email?(purchase) ? 1 : 0,
        "UTM Source" => utm_link&.utm_source,
        "UTM Medium" => utm_link&.utm_medium,
        "UTM Campaign" => utm_link&.utm_campaign,
        "UTM Term" => utm_link&.utm_term,
        "UTM Content" => utm_link&.utm_content
      }

      raise "This data is not JSON safe: #{data.inspect}" if !Rails.env.production? && !data.eql?(JSON.load(JSON.dump(data)))

      [data, custom_fields_data]
    end

    # Internal: Get the CSV field for taxation type - inclusive(Y) / exclusive(N) / not applicable(N/A)
    # Returns a value that logically answers - "Is Tax Included in Price ?"
    #
    # purchase - The purchase being serialized to CSV
    def determine_exclusive_tax_report_field(purchase)
      return unless purchase.was_purchase_taxable?

      purchase.was_tax_excluded_from_price ? 0 : 1
    end

    def pseudo_transliterate(string)
      return if string.nil?
      transliterated = ActiveSupport::Inflector.transliterate(string)
      return transliterated unless transliterated.include? "?"

      string
    end

    def sent_abandoned_cart_email?(purchase)
      return if purchase.order&.cart.blank?
      purchase.order.cart.sent_abandoned_cart_emails.any? { _1.installment.seller_id == purchase.link.user_id }
    end
end
