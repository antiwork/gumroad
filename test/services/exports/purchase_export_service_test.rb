# frozen_string_literal: true

require "test_helper"

# Ported from spec/services/exports/purchase_export_service_spec.rb (#5801).
#
# Every test reads the CSV back through the same three helpers the original spec
# used (`field_value` over `PURCHASE_FIELDS`), so a column reorder in the service
# moves the assertions with it rather than silently reading the wrong cell.
module PurchaseExportTestHelpers
  # The Gumroad-owned managed accounts the service resolves processors against.
  # Fixtures supply the Stripe one; PayPal and Braintree are created on demand
  # because no ported test needs them as fixtures.
  def ensure_gumroad_merchant_accounts
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create_merchant_account(user: nil, charge_processor_merchant_id: "acct_#{unique_suffix}")
    MerchantAccount.gumroad(PaypalChargeProcessor.charge_processor_id) ||
      create_merchant_account_paypal(user: nil, charge_processor_merchant_id: "paypal_#{unique_suffix}")
    MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id) ||
      create_merchant_account(user: nil, charge_processor_id: BraintreeChargeProcessor.charge_processor_id,
                              charge_processor_merchant_id: "braintree_#{unique_suffix}")
  end

  def setup_seller_product_and_purchase
    ensure_gumroad_merchant_accounts
    @seller = create_user
    @product = create_product(user: @seller, price_cents: 100_00)
    @purchase = create_purchase(link: @product, street_address: "Søéad", full_name: "Кочергина Дарья",
                                ip_address: "216.38.135.1")
  end

  # CsvSafe prefixes formula-injection characters. Mirrors the original spec's
  # helper so expectations stay in raw values.
  def csv_safe(value)
    return value if value.nil?
    str = value.to_s
    return value if str.empty?
    first = str[0]
    if first == "+" || first == "-"
      return value if str[1..]&.match?(/\A\d+\.?\d*\z/)
    end
    %w[= @ | % \r \t + -].include?(first) ? "'#{value}" : value
  end

  def field_index(name)
    Exports::PurchaseExportService::PURCHASE_FIELDS.index(name)
  end

  def field_value(row, name)
    row.fetch(field_index(name))
  end

  def cents_from_csv_dollars(value)
    (BigDecimal(value) * 100).to_i
  end

  def generate_csv(purchases = @seller.sales.where(purchase_state: Purchase::NON_GIFT_SUCCESS_STATES))
    Exports::PurchaseExportService.new(purchases).perform.read
  end

  def last_data_row
    rows = CSV.parse(generate_csv)
    rows[rows.size - 2] # last row has totals
  end

  def totals_row
    CSV.parse(generate_csv).last
  end
end

class PurchaseExportServiceTest < ActiveSupport::TestCase
  include PurchaseExportTestHelpers

  setup { setup_seller_product_and_purchase }

  test "uses the purchaser name if full_name is blank" do
    assert_equal "Кочергина Дарья", field_value(last_data_row, "Buyer Name")

    @purchase.update!(purchaser: create_user(name: "Gumbot"), full_name: nil)
    assert_equal "Gumbot", field_value(last_data_row, "Buyer Name")
  end

  test "includes the partial refund amount" do
    refunding_user = create_user
    @purchase.update!(fee_cents: 31)
    @purchase.refund_partial_purchase!(2301, refunding_user.id)
    @purchase.refund_partial_purchase!(3347, refunding_user.id)

    row = last_data_row
    assert_equal "1", field_value(row, "Refunded?")
    assert_equal "56.48", field_value(row, "Partial Refund ($)")
    assert_equal "0", field_value(row, "Fully Refunded?")
  end

  test "shows that the purchase has been fully refunded when multiple partial refunds have got it to that state" do
    refunding_user = create_user
    @purchase.update!(fee_cents: 31)
    @purchase.refund_partial_purchase!(2301, refunding_user.id)
    @purchase.refund_partial_purchase!(3347, refunding_user.id)
    @purchase.refund_partial_purchase!(4352, refunding_user.id)

    row = last_data_row
    assert_equal "1", field_value(row, "Refunded?")
    assert_equal "0.0", field_value(row, "Partial Refund ($)")
    assert_equal "1", field_value(row, "Fully Refunded?")
  end

  test "sets 'Disputed' and 'Dispute Won' to '1' when appropriate" do
    @purchase.fee_cents = 31
    @purchase.chargeback_date = @purchase.created_at + 1.minute
    @purchase.chargeback_reversed = true
    @purchase.save!

    row = last_data_row
    assert_equal "1", field_value(row, "Disputed?")
    assert_equal "1", field_value(row, "Dispute Won?")
  end

  test "transliterates information" do
    row = last_data_row
    assert_equal "Кочергина Дарья", field_value(row, "Buyer Name")
    assert_equal "Soead", field_value(row, "Street Address")
  end

  test "includes the variant price cents" do
    @product = create_product(price_cents: 100, user: @seller)
    category = create_variant_category(link: @product, title: "sizes")
    variant = create_variant(variant_category: category, name: "small", price_difference_cents: 350)
    @purchase = build_purchase(link: @product, price_cents: 450)
    @purchase.variant_attributes << variant
    @purchase.save!

    row = last_data_row
    assert_equal "1.0", field_value(row, "Item Price ($)")
    assert_equal "101.0", field_value(totals_row, "Item Price ($)")
    assert_equal "3.5", field_value(row, "Variants Price ($)")
    assert_equal "3.5", field_value(totals_row, "Variants Price ($)")
  end

  test "includes product rating" do
    create_product_review(purchase: @purchase, rating: 5, message: "This is a great product!")

    row = last_data_row
    assert_equal "5", field_value(row, "Rating")
    assert_equal "This is a great product!", field_value(row, "Review")
  end

  test "includes product rating posted by the giftee" do
    @purchase.update!(is_gift_sender_purchase: true)
    giftee_purchase = create_purchase(link: @product, is_gift_receiver_purchase: true, price_cents: 0)
    create_gift(link: @product, gifter_purchase: @purchase, giftee_purchase:)
    create_product_review(purchase: giftee_purchase, rating: 5)

    assert_equal "5", field_value(last_data_row, "Rating")
  end

  test "includes the purchase external id" do
    assert_equal csv_safe(Purchase.last.external_id.to_s), field_value(last_data_row, "Purchase ID")
  end

  test "includes the sku" do
    @product = create_product(price_range: "$1", skus_enabled: true, user: @seller)
    create_variant(variant_category: create_variant_category(link: @product, title: "Size"), name: "Small")
    create_variant(variant_category: create_variant_category(link: @product, title: "Color"), name: "Red")
    Product::SkusUpdaterService.new(product: @product).perform
    @purchase = build_purchase(link: @product, price_cents: 100)
    @purchase.variant_attributes << Sku.last
    @purchase.save!

    assert_equal csv_safe(Sku.last.external_id.to_s), field_value(last_data_row, "SKU ID")
  end

  test "shows the custom sku" do
    @product = create_product(price_range: "$1", skus_enabled: true, user: @seller)
    create_variant(variant_category: create_variant_category(link: @product, title: "Size"), name: "Small")
    create_variant(variant_category: create_variant_category(link: @product, title: "Color"), name: "Red")
    Product::SkusUpdaterService.new(product: @product).perform
    Sku.last.update!(custom_sku: "ABC123_Sm_Re")
    @purchase = build_purchase(link: @product, price_cents: 100)
    @purchase.variant_attributes << Sku.last
    @purchase.save!

    assert_equal "ABC123_Sm_Re", field_value(last_data_row, "SKU ID")
  end

  test "includes the offer code" do
    @purchase.update!(offer_code: create_offer_code(products: [@product], user: @seller, code: "sxsw", amount_cents: 100))

    assert_equal "sxsw", field_value(last_data_row, "Discount Code")
  end

  test "includes the affiliate information" do
    affiliate_user = create_affiliate_user
    @seller = create_affiliate_user(username: "momoney")
    @product = create_product(user: @seller)
    direct_affiliate = create_direct_affiliate(affiliate_user:, seller: @seller, affiliate_basis_points: 3000,
                                               products: [@product])
    @purchase = create_purchase_in_progress(link: @product, seller: @seller, affiliate: direct_affiliate)
    @purchase.process!
    @purchase.update_balance_and_mark_successful!

    row = last_data_row
    assert_equal affiliate_user.form_email, field_value(row, "Affiliate")
    assert_equal "0.02", field_value(row, "Affiliate commission ($)")
  end

  test "includes the discover information" do
    @purchase.update!(was_product_recommended: true)
    assert_equal "1", field_value(last_data_row, "Discover?")
  end

  test "includes the full country name when purchase doesn't have shipping details" do
    create_purchase(link: @product, email: "test@gumroad.com", zip_code: 94_103, state: "CA", country: "United States")
    create_purchase(link: @product, email: "test@gumroad.com", ip_address: "199.241.200.176")

    rows = CSV.parse(generate_csv)
    assert_equal "United States", field_value(rows[1], "Country")
    assert_equal "United States", field_value(rows[2], "Country")
    assert_equal "United States", field_value(rows[3], "Country")
  end

  test "includes buyers email if buyer has an account" do
    @purchase.update!(email: "some@email.com", purchaser: create_user(email: "some.other@email.com"))

    row = last_data_row
    assert_equal "some@email.com", field_value(row, "Purchase Email")
    assert_equal "some.other@email.com", field_value(row, "Buyer Email")
  end

  test "includes payment type" do
    {
      "paypal" => "PayPal",
      "mastercard" => "Card",
      "upi" => "UPI",
      "ideal" => "iDEAL",
      "bancontact" => "Bancontact",
      "klarna" => "Klarna",
      "alipay" => "Alipay",
    }.each do |card_type, label|
      @purchase.update!(card_type:)
      assert_equal label, field_value(last_data_row, "Payment Type"), "card_type #{card_type}"
    end

    @purchase.update!(card_type: nil)
    assert_nil field_value(last_data_row, "Payment Type")
  end

  test "includes PayPal fields only for PayPal marketplace sales" do
    @purchase.update!(card_type: "mastercard", processor_fee_cents: 12, processor_fee_cents_currency: "eur")
    assert_nil field_value(last_data_row, "PayPal Transaction ID")
    assert_nil field_value(last_data_row, "PayPal Fee Amount")
    assert_nil field_value(last_data_row, "PayPal Fee Currency")

    @purchase.update!(card_type: "paypal")
    assert_nil field_value(last_data_row, "PayPal Transaction ID")
    assert_nil field_value(last_data_row, "PayPal Fee Amount")
    assert_equal "0.0", field_value(totals_row, "PayPal Fee Amount")
    assert_nil field_value(last_data_row, "PayPal Fee Currency")

    @purchase.update!(card_type: "paypal", paypal_order_id: "someOrderId", stripe_transaction_id: "PayPalTx123")
    assert_equal "PayPalTx123", field_value(last_data_row, "PayPal Transaction ID")
    assert_equal "0.12", field_value(last_data_row, "PayPal Fee Amount")
    assert_equal "0.12", field_value(totals_row, "PayPal Fee Amount")
    assert_equal "eur", field_value(last_data_row, "PayPal Fee Currency")
  end

  test "includes PayPal fields with fee amount in USD" do
    @purchase.update!(card_type: "mastercard", processor_fee_cents: 13, processor_fee_cents_currency: "usd")
    @purchase.update!(card_type: "paypal", paypal_order_id: "someOrderId", stripe_transaction_id: "PayPalTx123")

    row = last_data_row
    assert_equal "PayPalTx123", field_value(row, "PayPal Transaction ID")
    assert_equal "0.13", field_value(row, "PayPal Fee Amount")
    assert_equal "usd", field_value(row, "PayPal Fee Currency")
  end

  test "includes PayPal fields with fee amount in GBP" do
    @purchase.update!(card_type: "mastercard", processor_fee_cents: 14, processor_fee_cents_currency: "gbp")
    @purchase.update!(card_type: "paypal", paypal_order_id: "someOrderId", stripe_transaction_id: "PayPalTx123")

    row = last_data_row
    assert_equal "PayPalTx123", field_value(row, "PayPal Transaction ID")
    assert_equal "0.14", field_value(row, "PayPal Fee Amount")
    assert_equal "gbp", field_value(row, "PayPal Fee Currency")
  end

  test "includes Stripe fields only for Stripe Connect sales" do
    assert_nil field_value(last_data_row, "Stripe Transaction ID")
    assert_nil field_value(last_data_row, "Stripe Fee Amount")
    assert_nil field_value(last_data_row, "Stripe Fee Currency")

    @purchase.update!(merchant_account: create_merchant_account_paypal, paypal_order_id: "someOrderId",
                      processor_fee_cents: 12, processor_fee_cents_currency: "eur",
                      stripe_transaction_id: "PayPalTx123")
    assert_nil field_value(last_data_row, "Stripe Transaction ID")
    assert_nil field_value(last_data_row, "Stripe Fee Amount")
    assert_nil field_value(last_data_row, "Stripe Fee Currency")

    # A Gumroad-managed Stripe account is NOT Stripe Connect, so the columns stay blank.
    @purchase.update!(merchant_account: create_merchant_account, processor_fee_cents: 12,
                      processor_fee_cents_currency: "eur", stripe_transaction_id: "ch_12345")
    assert_nil field_value(last_data_row, "Stripe Transaction ID")
    assert_nil field_value(last_data_row, "Stripe Fee Amount")
    assert_nil field_value(last_data_row, "Stripe Fee Currency")

    @purchase.update!(merchant_account: create_merchant_account_stripe_connect, processor_fee_cents: 12,
                      processor_fee_cents_currency: "eur", stripe_transaction_id: "ch_12345")
    assert_equal "ch_12345", field_value(last_data_row, "Stripe Transaction ID")
    assert_equal "0.12", field_value(last_data_row, "Stripe Fee Amount")
    assert_equal "0.12", field_value(totals_row, "Stripe Fee Amount")
    assert_equal "eur", field_value(last_data_row, "Stripe Fee Currency")
  end

  test "includes a field indicating if the purchase was purchasing power parity discounted" do
    assert_equal "0", field_value(last_data_row, "Purchasing Power Parity Discounted?")

    @purchase.update!(is_purchasing_power_parity_discounted: true)
    assert_equal "1", field_value(last_data_row, "Purchasing Power Parity Discounted?")
  end

  test "includes a field indicating if the purchase was upsold" do
    assert_equal "0", field_value(last_data_row, "Upsold?")

    create_upsell_purchase(purchase: @purchase,
                           upsell: create_upsell(seller: @seller, product: @product, cross_sell: true))
    assert_equal "1", field_value(last_data_row, "Upsold?")
  end

  test "generates csv with default purchase fields and extra purchase fields" do
    # "Order Number" is deliberately reused: a custom field may share a default
    # field's name, and both columns must appear with their own values.
    create_purchase_custom_field(purchase: @purchase, name: "Age", value: "30")
    create_purchase_custom_field(purchase: @purchase, name: "Order Number", value: "O123")
    # The represented products' custom fields appear even when the purchase never set them.
    @product.custom_fields << [create_custom_field(name: "Age", seller: @seller),
                               create_custom_field(name: "Size", seller: @seller)]

    rows = CSV.parse(generate_csv)
    headers, row = rows.first, rows[rows.size - 2]

    assert_equal Exports::PurchaseExportService::PURCHASE_FIELDS + ["Age", "Order Number", "Size"], headers
    assert_includes headers, "Tax Type"

    assert_equal 2, headers.count("Order Number")
    assert_equal @purchase.external_id_numeric.to_s, row.fetch(headers.index("Order Number"))
    assert_equal "O123", row.fetch(headers.rindex("Order Number"))

    assert_equal "30", row.fetch(headers.index("Age"))
    assert_nil row.fetch(headers.index("Size"))
  end

  test "raises error if a value is not JSON safe" do
    assert_nothing_raised { generate_csv }

    [Time.now.utc, Time.zone.now, Date.today].each do |unsafe_value|
      Purchase.any_instance.stubs(:license_key).returns(unsafe_value)
      error = assert_raises(StandardError) { generate_csv }
      assert_match(/not JSON safe/, error.message)
    end
  end

  test "shows whether the license key is enabled (not disabled)" do
    assert_nil field_value(last_data_row, "License Key Enabled?")

    @product.update!(is_licensed: true)
    @purchase.create_license!
    assert_equal "1", field_value(last_data_row, "License Key Enabled?")

    @purchase.license.disable!
    assert_equal "0", field_value(last_data_row, "License Key Enabled?")
  end

  test "includes licence key" do
    @product.update!(is_licensed: true)
    @purchase.create_license!

    assert @purchase.license_key.present?
    assert_equal @purchase.license_key, field_value(last_data_row, "License Key")
  end

  test "includes licence key belonging to the giftee" do
    @product.update!(is_licensed: true)
    @purchase.update!(is_gift_sender_purchase: true)
    giftee_purchase = create_purchase(link: @product, is_gift_receiver_purchase: true, price_cents: 0)
    create_gift(link: @product, gifter_purchase: @purchase, giftee_purchase:)
    giftee_purchase.create_license!

    assert @purchase.license_key.blank?
    assert giftee_purchase.license_key.present?
    assert_equal giftee_purchase.license_key, field_value(last_data_row, "License Key")
  end

  test "includes license key activation count" do
    @product.update!(is_licensed: true)
    @purchase.create_license!

    assert_equal "0", field_value(last_data_row, "License Key Activation Count")

    @purchase.license.update!(uses: 5)
    assert_equal "5", field_value(last_data_row, "License Key Activation Count")
  end

  test "includes license key activation count for giftee" do
    @product.update!(is_licensed: true)
    @purchase.update!(is_gift_sender_purchase: true)
    giftee_purchase = create_purchase(link: @product, is_gift_receiver_purchase: true, price_cents: 0)
    create_gift(link: @product, gifter_purchase: @purchase, giftee_purchase:)
    giftee_purchase.create_license!
    giftee_purchase.license.update!(uses: 3)

    assert_equal "3", field_value(last_data_row, "License Key Activation Count")
  end

  test "shows nil for license key activation count when no license exists" do
    assert_nil field_value(last_data_row, "License Key Activation Count")
  end

  test "shows whether the purchase is associated to a sent abandoned cart email" do
    assert_equal "0", field_value(last_data_row, "Sent Abandoned Cart Email?")

    cart = create_cart(order: create_order(purchases: [@purchase]))
    create_sent_abandoned_cart_email(cart:) # for a different seller's product
    assert_equal "0", field_value(last_data_row, "Sent Abandoned Cart Email?")

    workflow = create_abandoned_cart_workflow(seller: @seller)
    create_sent_abandoned_cart_email(cart:, installment: workflow.installments.sole)
    assert_equal "1", field_value(last_data_row, "Sent Abandoned Cart Email?")
  end

  test "includes access revoked status" do
    assert_equal "0", field_value(last_data_row, "Access Revoked?")

    @purchase.update!(is_access_revoked: true)
    assert_equal "1", field_value(last_data_row, "Access Revoked?")
  end

  test "includes the tip amount in USD when the purchase has a tip" do
    create_tip(purchase: @purchase, value_usd_cents: 100, created_at: 2.minutes.ago)
    create_tip(purchase: create_purchase(link: @product, seller: @seller), value_usd_cents: 450,
               created_at: 1.minute.ago)

    assert_equal "4.5", field_value(last_data_row, "Tip ($)")
    assert_equal "5.5", field_value(totals_row, "Tip ($)")
  end

  test "shows 0 for the tip amount when the purchase has no tip" do
    assert_equal "0.0", field_value(last_data_row, "Tip ($)")
    assert_equal "0.0", field_value(totals_row, "Tip ($)")
  end

  test "includes blank values for UTM parameters when the purchase was not driven by a UTM link" do
    row = last_data_row
    assert_nil field_value(row, "UTM Source")
    assert_nil field_value(row, "UTM Medium")
    assert_nil field_value(row, "UTM Campaign")
    assert_nil field_value(row, "UTM Term")
    assert_nil field_value(row, "UTM Content")
  end

  test "includes the UTM parameters when the purchase was driven by a UTM link" do
    utm_link = create_utm_link(utm_source: "twitter", utm_medium: "social", utm_campaign: "campaign",
                               utm_term: "gumroad", utm_content: "hello-world")
    create_utm_link_driven_sale(utm_link:, purchase: @purchase)

    row = last_data_row
    assert_equal "twitter", field_value(row, "UTM Source")
    assert_equal "social", field_value(row, "UTM Medium")
    assert_equal "campaign", field_value(row, "UTM Campaign")
    assert_equal "gumroad", field_value(row, "UTM Term")
    assert_equal "hello-world", field_value(row, "UTM Content")
  end

  test "keeps v2 API web CSV parity fields aligned with export values" do
    utm_link = create_utm_link(seller: @seller, utm_source: "newsletter", utm_medium: "email",
                               utm_campaign: "launch", utm_term: "founders", utm_content: "hero")
    create_utm_link_driven_sale(utm_link:, purchase: @purchase)
    create_tip(purchase: @purchase, value_usd_cents: 350)
    category = create_variant_category(link: @product, title: "Format")
    variant = create_variant(variant_category: category, name: "Premium", price_difference_cents: 250)
    @purchase.variant_attributes << variant
    create_product_review(purchase: @purchase, rating: 5, message: "Worth it")
    subscription = create_subscription(link: @product, user: @seller)
    subscription.update!(user_requested_cancellation_at: Time.zone.parse("2026-01-02 03:04:05"),
                         cancelled_at: Date.new(2026, 1, 10))
    preorder = create_preorder(seller: @seller, preorder_link: create_preorder_link(link: @product),
                               created_at: Time.zone.parse("2025-12-01 08:00:00"))
    cart = create_cart(order: create_order(purchases: [@purchase]))
    workflow = create_abandoned_cart_workflow(seller: @seller)
    create_sent_abandoned_cart_email(cart:, installment: workflow.installments.sole)

    @purchase.update!(
      was_purchase_taxable: true,
      was_tax_excluded_from_price: false,
      tax_cents: 123,
      shipping_cents: 456,
      is_access_revoked: true,
      subscription:,
      preorder:,
      is_original_subscription_purchase: true,
      is_preorder_authorization: false,
      merchant_account: create_merchant_account_stripe_connect(user: @seller),
      processor_fee_cents: 78,
      processor_fee_cents_currency: "usd",
      stripe_transaction_id: "ch_123"
    )

    row = last_data_row
    api_json = @purchase.reload.as_json(version: 2)

    assert_equal field_value(row, "UTM Source"), api_json[:utm_source]
    assert_equal field_value(row, "UTM Medium"), api_json[:utm_medium]
    assert_equal field_value(row, "UTM Campaign"), api_json[:utm_campaign]
    assert_equal field_value(row, "UTM Term"), api_json[:utm_term]
    assert_equal field_value(row, "UTM Content"), api_json[:utm_content]
    assert_equal field_value(row, "Tax Type"), api_json[:tax_label]
    assert_equal field_value(row, "Tax Included in Price?") == "1", api_json[:tax_included_in_price]
    assert_equal "stripe_connect", api_json[:payment_processor]
    assert_equal field_value(row, "Stripe Transaction ID"), api_json[:processor_transaction_id]
    assert_equal field_value(row, "Stripe Fee Currency"), api_json[:processor_fee_currency]
    assert_equal field_value(row, "Access Revoked?") == "1", api_json[:access_revoked]
    assert_equal preorder.reload.created_at, api_json[:preorder_authorization_time]
    assert_equal field_value(row, "Review"), api_json[:review]
    assert_equal subscription.reload.user_requested_cancellation_at, api_json[:cancellation_date]
    assert_equal subscription.termination_date, api_json[:subscription_end_date]
    assert_equal field_value(row, "Sent Abandoned Cart Email?") == "1", api_json[:sent_abandoned_cart_email]

    assert_equal cents_from_csv_dollars(field_value(row, "Tip ($)")), api_json[:tip_cents]
    assert_equal cents_from_csv_dollars(field_value(row, "Taxes ($)")), api_json[:tax_cents]
    assert_equal cents_from_csv_dollars(field_value(row, "Shipping ($)")), api_json[:shipping_cents]
    assert_equal cents_from_csv_dollars(field_value(row, "Stripe Fee Amount")), api_json[:processor_fee_cents]
    assert_equal cents_from_csv_dollars(field_value(row, "Variants Price ($)")), api_json[:variants_price_cents]
  end
end

class PurchaseExportServiceSubscriptionsTest < ActiveSupport::TestCase
  include PurchaseExportTestHelpers

  setup do
    setup_seller_product_and_purchase
    @product = create_subscription_product(user: @seller, price_cents: 10_00)
    @subscription = create_subscription(link: @product)
    @purchase = create_purchase(link: @product, subscription: @subscription,
                                is_original_subscription_purchase: true)
  end

  test "marks recurring charges" do
    row = last_data_row
    assert_equal "0", field_value(row, "Recurring Charge?")
    assert_equal "monthly", field_value(row, "Recurrence")
    assert_nil field_value(row, "Subscription End Date")

    create_purchase(link: @product, subscription: @subscription)
    assert_equal "1", field_value(last_data_row, "Recurring Charge?")
  end

  test "marks free trial purchases" do
    @purchase.update!(purchase_state: "not_charged", is_free_trial_purchase: true)

    assert_equal "1", field_value(last_data_row, "Free trial purchase?")
  end

  test "includes when the subscription was terminated" do
    @subscription.update!(cancelled_at: 1.day.ago)

    row = last_data_row
    assert_equal "0", field_value(row, "Recurring Charge?")
    assert_equal "monthly", field_value(row, "Recurrence")
    assert_equal @subscription.cancelled_at.to_date.to_s, field_value(row, "Subscription End Date")
  end

  test "includes the cancellation date when the subscription was cancelled" do
    freeze_time do
      @subscription.update!(user_requested_cancellation_at: Time.current, cancelled_at: 1.month.from_now)

      assert_equal Time.current.to_s, field_value(last_data_row, "Cancellation Date")
    end
  end

  test "returns nil for cancellation date when subscription has not been cancelled" do
    assert_nil field_value(last_data_row, "Cancellation Date")
  end
end

class PurchaseExportServicePreordersTest < ActiveSupport::TestCase
  include PurchaseExportTestHelpers

  setup do
    setup_seller_product_and_purchase
    @product = create_product(user: @seller, is_in_preorder_state: true, price_cents: 10_00)
    @preorder_link = create_preorder_link(link: @product, release_at: 2.days.from_now)
    @authorization_purchase = create_purchase(link: @product, is_preorder_authorization: true)
  end

  test "marks preorder authorizations" do
    row = last_data_row
    assert_equal @authorization_purchase.created_at.to_date.to_s, field_value(row, "Purchase Date")
    assert_equal @authorization_purchase.created_at.to_time.to_s, field_value(row, "Purchase Time (UTC timezone)")
    assert_equal "1", field_value(row, "Pre-order authorization?")
  end

  test "includes the preorder authorization date-time" do
    preorder_auth_time = 2.days.ago
    preorder = nil
    travel_to(preorder_auth_time) do
      # The original spec ran the real `preorder.authorize!`, which tokenizes a
      # card against Stripe. What the export reads is only the authorization
      # purchase's created_at, so land the same end state — an authorized
      # preorder whose authorization purchase is dated here — without the
      # round trip.
      authorization_purchase = build_purchase(link: @product, is_preorder_authorization: true,
                                              purchase_state: "in_progress")
      preorder = @preorder_link.build_preorder(authorization_purchase)
      authorization_purchase.save!
      preorder.save!
      authorization_purchase.update!(purchase_state: "preorder_authorization_successful")
      preorder.mark_authorization_successful!
    end

    @preorder_link.update!(release_at: 2.days.from_now)
    @product.update!(is_in_preorder_state: false)
    charge_purchase = create_purchase(link: @product, preorder:, seller: @seller)

    row = last_data_row
    assert_equal charge_purchase.email, field_value(row, "Purchase Email")
    assert_equal charge_purchase.created_at.to_date.to_s, field_value(row, "Purchase Date")
    assert_equal charge_purchase.created_at.to_time.to_s, field_value(row, "Purchase Time (UTC timezone)")
    assert_equal preorder_auth_time.to_time.to_s, field_value(row, "Pre-order authorization time (UTC timezone)")
  end
end

class PurchaseExportServiceSalesTaxTest < ActiveSupport::TestCase
  include PurchaseExportTestHelpers

  setup do
    setup_seller_product_and_purchase
    @purchase.fee_cents = 31
  end

  test "displays (blank) when purchase is not taxable" do
    @purchase.was_purchase_taxable = false
    @purchase.save!

    row = last_data_row
    assert_equal "100.0", field_value(row, "Subtotal ($)")
    assert_equal "0.0", field_value(row, "Taxes ($)")
    assert_equal "", field_value(row, "Tax Type")
    assert_equal "0.0", field_value(row, "Shipping ($)")
    assert_equal "100.0", field_value(row, "Sale Price ($)")
    assert_equal "0.31", field_value(row, "Fees ($)")
    assert_equal "99.69", field_value(row, "Net Total ($)")
    assert_nil field_value(row, "Tax Included in Price?")
  end

  test "displays 0 for 'Is Tax Included in Price ?' when tax was excluded from purchase price" do
    @purchase.was_purchase_taxable = true
    @purchase.was_tax_excluded_from_price = true
    @purchase.tax_cents = 1_10
    @purchase.save!

    row = last_data_row
    assert_equal "98.9", field_value(row, "Subtotal ($)")
    assert_equal "1.1", field_value(row, "Taxes ($)")
    assert_equal "0.0", field_value(row, "Shipping ($)")
    assert_equal "100.0", field_value(row, "Sale Price ($)")
    assert_equal "0.31", field_value(row, "Fees ($)")
    assert_equal "99.69", field_value(row, "Net Total ($)")
    assert_equal "0", field_value(row, "Tax Included in Price?")
  end

  test "displays 1 for 'Is Tax Included in Price ?' when tax was not excluded from purchase price" do
    @purchase.was_purchase_taxable = true
    @purchase.was_tax_excluded_from_price = false
    @purchase.tax_cents = 1_10
    @purchase.save!

    row = last_data_row
    assert_equal "98.9", field_value(row, "Subtotal ($)")
    assert_equal "1.1", field_value(row, "Taxes ($)")
    assert_equal "0.0", field_value(row, "Shipping ($)")
    assert_equal "100.0", field_value(row, "Sale Price ($)")
    assert_equal "0.31", field_value(row, "Fees ($)")
    assert_equal "99.69", field_value(row, "Net Total ($)")
    assert_equal "1", field_value(row, "Tax Included in Price?")
  end

  test "has subtotal that does not include the sales tax" do
    @purchase.was_purchase_taxable = true
    @purchase.was_tax_excluded_from_price = true
    @purchase.tax_cents = 1_10
    @purchase.save!

    row, totals = last_data_row, totals_row
    assert_equal "98.9", field_value(row, "Subtotal ($)")
    assert_equal "98.9", field_value(totals, "Subtotal ($)")
    assert_equal "1.1", field_value(row, "Taxes ($)")
    assert_equal "1.1", field_value(totals, "Taxes ($)")
    assert_equal "0.0", field_value(row, "Shipping ($)")
    assert_equal "0.0", field_value(totals, "Shipping ($)")
    assert_equal "100.0", field_value(row, "Sale Price ($)")
    assert_equal "100.0", field_value(totals, "Sale Price ($)")
    assert_equal "0.31", field_value(row, "Fees ($)")
    assert_equal "0.31", field_value(totals, "Fees ($)")
    assert_equal "99.69", field_value(row, "Net Total ($)")
    assert_equal "99.69", field_value(totals, "Net Total ($)")
    assert_equal "0", field_value(row, "Tax Included in Price?")
  end

  test "has subtotal that does not include the tax collected by Gumroad" do
    @purchase.was_purchase_taxable = true
    @purchase.was_tax_excluded_from_price = true
    @purchase.gumroad_tax_cents = 1_80
    @purchase.save!

    row, totals = last_data_row, totals_row
    assert_equal "100.0", field_value(row, "Subtotal ($)")
    assert_equal "100.0", field_value(totals, "Subtotal ($)")
    assert_equal "1.8", field_value(row, "Taxes ($)")
    assert_equal "1.8", field_value(totals, "Taxes ($)")
    assert_equal "0.0", field_value(row, "Shipping ($)")
    assert_equal "0.0", field_value(totals, "Shipping ($)")
    assert_equal "100.0", field_value(row, "Sale Price ($)")
    assert_equal "100.0", field_value(totals, "Sale Price ($)")
    assert_equal "0.31", field_value(row, "Fees ($)")
    assert_equal "0.31", field_value(totals, "Fees ($)")
    assert_equal "99.69", field_value(row, "Net Total ($)")
    assert_equal "99.69", field_value(totals, "Net Total ($)")
    assert_equal "0", field_value(row, "Tax Included in Price?")
  end

  # One test per case, generated the same way the RSpec original generated one
  # context per case, so a single wrong label names its own country.
  [
    { country: "IT", rate: 0.22, excluded: nil, expected_type: "VAT" },
    { country: "AU", rate: 0.10, excluded: nil, expected_type: "GST" },
    { country: "SG", rate: 0.07, excluded: nil, expected_type: "GST" },
    { country: "IN", rate: 0.18, excluded: nil, expected_type: "GST" },
    { country: "JP", rate: 0.10, excluded: nil, expected_type: "CT" },
    { country: "MY", rate: 0.08, excluded: nil, expected_type: "Service tax" },
    { country: "US", rate: 0.085, excluded: true, expected_type: "Sales tax" },
    { country: "US", rate: 0.085, excluded: false, expected_type: "Sales tax" },
    { country: nil, rate: nil, excluded: true, expected_type: "Sales tax" },
  ].each do |test_case|
    country, rate, excluded, expected_type = test_case.values_at(:country, :rate, :excluded, :expected_type)

    test "tax type is #{expected_type} when country is #{country.inspect}, rate is #{rate.inspect}, and excluded is #{excluded.inspect}" do
      @purchase.update!(
        was_purchase_taxable: true,
        was_tax_excluded_from_price: excluded,
        tax_cents: 100,
        zip_tax_rate: country && create_zip_tax_rate(country:, combined_rate: rate, zip_code: nil, state: nil)
      )

      assert_equal expected_type, field_value(last_data_row, "Tax Type")
    end
  end
end

class PurchaseExportServiceBuyerCurrencyTest < ActiveSupport::TestCase
  include PurchaseExportTestHelpers

  setup { setup_seller_product_and_purchase }

  test "leaves them blank for a canonical USD sale" do
    row = last_data_row
    assert_nil field_value(row, "Buyer Currency")
    assert_nil field_value(row, "Buyer Total")
    assert_nil field_value(row, "Buyer Refunded Total")
  end

  test "reports the buyer currency and charged total for a presentment sale" do
    create_purchase_presentment(purchase: @purchase, presentment_currency: Currency::CAD,
                                presentment_price_cents: 12_00, presentment_tip_cents: 0,
                                presentment_seller_tax_cents: 0, presentment_gumroad_tax_cents: 1_50,
                                presentment_shipping_cents: 0, presentment_total_cents: 13_50)

    row = last_data_row
    assert_equal "CAD", field_value(row, "Buyer Currency")
    assert_equal "13.5", field_value(row, "Buyer Total")
    assert_equal "0.0", field_value(row, "Buyer Refunded Total")
  end

  test "sums the refunds carrying a buyer-currency snapshot" do
    create_purchase_presentment(purchase: @purchase, presentment_currency: Currency::CAD)
    create_refund(purchase: @purchase, amount_cents: 5_00).update!(
      json_data: { presentment_currency: Currency::CAD, presentment_amount_cents: 7_00 }
    )
    create_refund(purchase: @purchase, amount_cents: 3_00).update!(
      json_data: { presentment_currency: Currency::CAD, presentment_amount_cents: 4_25 }
    )

    assert_equal "11.25", field_value(last_data_row, "Buyer Refunded Total")
  end

  test "leaves the buyer refunded total blank when a refund predates buyer-currency snapshots" do
    create_purchase_presentment(purchase: @purchase, presentment_currency: Currency::CAD)
    create_refund(purchase: @purchase, amount_cents: 5_00).update!(
      json_data: { presentment_currency: Currency::CAD, presentment_amount_cents: 7_00 }
    )
    # No snapshot: this refund happened before the feature shipped, so its buyer-currency
    # amount is genuinely unknown. Publishing "7.0" would understate what the buyer got
    # back and a seller reconciling against their statement could not tell. An empty cell
    # says "unknown" honestly.
    create_refund(purchase: @purchase, amount_cents: 1_00)

    assert_nil field_value(last_data_row, "Buyer Refunded Total")
  end

  test "does not divide zero-decimal currencies by 100" do
    create_purchase_presentment(purchase: @purchase, presentment_currency: Currency::JPY,
                                presentment_price_cents: 1_500, presentment_tip_cents: 0,
                                presentment_seller_tax_cents: 0, presentment_gumroad_tax_cents: 0,
                                presentment_shipping_cents: 0, presentment_total_cents: 1_500)

    row = last_data_row
    assert_equal "JPY", field_value(row, "Buyer Currency")
    assert_equal "1500", field_value(row, "Buyer Total")
  end

  test "keeps the canonical USD columns and the totals row unchanged" do
    create_purchase_presentment(purchase: @purchase, presentment_currency: Currency::CAD)

    assert_equal "100.0", field_value(last_data_row, "Sale Price ($)")
    assert_equal "100.0", field_value(totals_row, "Sale Price ($)")
    # Buyer amounts are excluded from the totals row on purpose: adding up amounts
    # across different buyer currencies would produce a meaningless number.
    assert_nil field_value(totals_row, "Buyer Total")
    assert_nil field_value(totals_row, "Buyer Refunded Total")
  end

  test "does not issue per-purchase presentment or refund queries" do
    create_purchase_presentment(purchase: @purchase, presentment_currency: Currency::CAD)
    create_purchase_presentment(purchase: create_purchase(link: @product))

    per_row_queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      if sql.include?("purchase_presentments") || sql.include?("FROM `refunds`")
        # IN-lists are the batched preload; equality probes are the N+1 shape.
        per_row_queries << sql if sql.match?(/purchase_id`? = /)
      end
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { generate_csv }

    assert_empty per_row_queries
  end
end

class PurchaseExportServiceExportTest < ActiveSupport::TestCase
  include PurchaseExportTestHelpers

  test "queues the export when async delivery is forced" do
    seller = create_user
    recipient = create_user
    EsClient.stubs(:count).returns({ "count" => 1 })

    result = nil
    assert_difference -> { SalesExport.count }, 1 do
      result = Exports::PurchaseExportService.export(seller:, recipient:, force_async: true)
    end

    export = SalesExport.last!
    assert_equal false, result
    assert_equal recipient, export.recipient
    assert_includes Exports::Sales::CreateAndEnqueueChunksWorker.jobs.map { _1["args"] }, [export.id]
  end
end
