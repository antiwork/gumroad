# frozen_string_literal: true

require "spec_helper"

describe Exports::PurchaseExportService do
  describe "#perform" do
    before do
      @seller = create(:user)
      @product = create(:product, user: @seller, price_cents: 100_00)
      @purchase = create(:purchase, link: @product, street_address: "Søéad", full_name: "Кочергина Дарья", ip_address: "216.38.135.1")
    end

    it "uses the purchaser name if full_name is blank" do
      row = last_data_row
      expect(field_value(row, "Buyer Name")).to eq("Кочергина Дарья")

      @purchase.update!(purchaser: create(:named_user), full_name: nil)
      row = last_data_row
      expect(field_value(row, "Buyer Name")).to eq("Gumbot")
    end

    it "includes the partial refund amount" do
      refunding_user = create(:user)
      @purchase.fee_cents = 31
      @purchase.save!
      @purchase.refund_partial_purchase!(2301, refunding_user.id)
      @purchase.refund_partial_purchase!(3347, refunding_user.id)

      row = last_data_row
      expect(field_value(row, "Refunded?")).to eq("1")
      expect(field_value(row, "Partial Refund ($)")).to eq("56.48")
      expect(field_value(row, "Fully Refunded?")).to eq("0")
    end

    it "shows that the purchase has been fully refunded when multiple partial refunds have got it to that state" do
      refunding_user = create(:user)
      @purchase.fee_cents = 31
      @purchase.save!
      @purchase.refund_partial_purchase!(2301, refunding_user.id)
      @purchase.refund_partial_purchase!(3347, refunding_user.id)
      @purchase.refund_partial_purchase!(4352, refunding_user.id)

      row = last_data_row
      expect(field_value(row, "Refunded?")).to eq("1")
      expect(field_value(row, "Partial Refund ($)")).to eq("0.0")
      expect(field_value(row, "Fully Refunded?")).to eq("1")
    end

    it "sets 'Disputed' and 'Dispute Won' to '1' when appropriate" do
      @purchase.fee_cents = 31
      @purchase.chargeback_date = @purchase.created_at + 1.minute
      @purchase.chargeback_reversed = true
      @purchase.save!

      row = last_data_row
      expect(field_value(row, "Disputed?")).to eq("1")
      expect(field_value(row, "Dispute Won?")).to eq("1")
    end

    it "transliterates information" do
      row = last_data_row
      expect(field_value(row, "Buyer Name")).to eq("Кочергина Дарья")
      expect(field_value(row, "Street Address")).to eq("Soead")
    end

    it "includes the variant price cents", :vcr do
      @product = create(:product, price_cents: 100, user: @seller)
      @category = create(:variant_category, title: "sizes", link: @product)
      @variant = create(:variant, name: "small", price_difference_cents: 350, variant_category: @category)
      @purchase = build(:purchase, link: @product, chargeable: build(:chargeable), perceived_price_cents: 450, save_card: false)
      @purchase.variant_attributes << @variant
      @purchase.process!

      row = last_data_row
      expect(field_value(row, "Item Price ($)")).to eq("1.0")
      expect(field_value(totals_row, "Item Price ($)")).to eq("101.0")
      expect(field_value(row, "Variants Price ($)")).to eq("3.5")
      expect(field_value(totals_row, "Variants Price ($)")).to eq("3.5")
    end

    it "includes product rating" do
      create(:product_review, purchase: @purchase, rating: 5, message: "This is a great product!")

      expect(field_value(last_data_row, "Rating")).to eq("5")
      expect(field_value(last_data_row, "Review")).to eq("This is a great product!")
    end

    it "includes product rating posted by the giftee" do
      @purchase.update!(is_gift_sender_purchase: true)
      giftee_purchase = create(:purchase, :gift_receiver, link: @product)
      create(:gift, link: @product, gifter_purchase: @purchase, giftee_purchase:)
      create(:product_review, purchase: giftee_purchase, rating: 5)

      expect(field_value(last_data_row, "Rating")).to eq("5")
    end

    it "includes the purchase external id" do
      expect(field_value(last_data_row, "Purchase ID")).to eq(Purchase.last.external_id.to_s)
    end

    it "includes the sku", :vcr do
      @product = create(:product, price_range: "$1", skus_enabled: true, user: @seller)
      @category1 = create(:variant_category, title: "Size", link: @product)
      @variant1 = create(:variant, variant_category: @category1, name: "Small")
      @category2 = create(:variant_category, title: "Color", link: @product)
      @variant2 = create(:variant, variant_category: @category2, name: "Red")
      Product::SkusUpdaterService.new(product: @product).perform
      @purchase = build(:purchase, link: @product, chargeable: build(:chargeable), perceived_price_cents: 100, save_card: false, price_range: 1)
      @purchase.variant_attributes << Sku.last
      @purchase.process!

      expect(field_value(last_data_row, "SKU ID")).to eq(Sku.last.external_id.to_s)
    end

    it "shows the custom sku", :vcr do
      @product = create(:product, price_range: "$1", skus_enabled: true, user: @seller)
      @category1 = create(:variant_category, title: "Size", link: @product)
      @variant1 = create(:variant, variant_category: @category1, name: "Small")
      @category2 = create(:variant_category, title: "Color", link: @product)
      @variant2 = create(:variant, variant_category: @category2, name: "Red")
      Product::SkusUpdaterService.new(product: @product).perform
      Sku.last.update_attribute(:custom_sku, "ABC123_Sm_Re")
      @purchase = build(:purchase, link: @product, chargeable: build(:chargeable), perceived_price_cents: 100, save_card: false, price_range: 1)
      @purchase.variant_attributes << Sku.last
      @purchase.process!

      expect(field_value(last_data_row, "SKU ID")).to eq("ABC123_Sm_Re")
    end

    describe "subscriptions" do
      before do
        @product = create(:subscription_product, user: @seller, price_cents: 10_00)
        @subscription = create(:subscription, link: @product)
        @purchase = create(:purchase, link: @product, subscription: @subscription, is_original_subscription_purchase: true)
      end

      it "marks recurring charges" do
        row = last_data_row
        expect(field_value(row, "Recurring Charge?")).to eq("0")
        expect(field_value(row, "Recurrence")).to eq("monthly")
        expect(field_value(row, "Subscription End Date")).to eq(nil)

        create(:purchase, link: @product, subscription: @subscription)
        expect(field_value(last_data_row, "Recurring Charge?")).to eq("1")
      end

      it "marks free trial purchases" do
        @purchase.update!(purchase_state: "not_charged", is_free_trial_purchase: true)

        row = last_data_row
        expect(field_value(row, "Free trial purchase?")).to eq("1")
      end

      it "includes when the subscription was terminated" do
        @subscription.update_attribute(:cancelled_at, 1.day.ago)

        row = last_data_row
        expect(field_value(row, "Recurring Charge?")).to eq("0")
        expect(field_value(row, "Recurrence")).to eq("monthly")
        expect(field_value(row, "Subscription End Date")).to eq(@subscription.cancelled_at.to_date.to_s)
      end
    end

    describe "preorders" do
      before do
        @product = create(:product, is_in_preorder_state: true, user: @seller, price_cents: 10_00)
        @preorder_link = create(:preorder_link, link: @product, release_at: 2.days.from_now)
        @authorization_purchase = create(:purchase, link: @product, is_preorder_authorization: true)
      end

      it "marks preorder authorizations" do
        row = last_data_row
        expect(field_value(row, "Purchase Date")).to eq(@authorization_purchase.created_at.to_date.to_s)
        expect(field_value(row, "Purchase Time (UTC timezone)")).to eq(@authorization_purchase.created_at.to_time.to_s)
        expect(field_value(row, "Pre-order authorization?")).to eq("1")
      end

      it "includes the preorder authorization date-time", :vcr do
        preorder_auth_time = 2.days.ago
        travel_to(preorder_auth_time) do
          authorization_purchase = build(:purchase,
                                         link: @product, chargeable: build(:chargeable),
                                         purchase_state: "in_progress", is_preorder_authorization: true)
          @preorder = @preorder_link.build_preorder(authorization_purchase)
          @preorder.authorize!
          @preorder.mark_authorization_successful!
        end

        @preorder_link.update!(release_at: 2.days.from_now)
        @product.update_attribute(:is_in_preorder_state, false)
        @preorder.charge!
        charge_purchase = @preorder.purchases.last

        row = last_data_row
        expect(field_value(row, "Purchase Email")).to eq(charge_purchase.email)
        expect(field_value(row, "Purchase Date")).to eq(charge_purchase.created_at.to_date.to_s)
        expect(field_value(row, "Purchase Time (UTC timezone)")).to eq(charge_purchase.created_at.to_time.to_s)
        expect(field_value(row, "Pre-order authorization time (UTC timezone)")).to eq(preorder_auth_time.to_time.to_s)
      end
    end

    it "includes the offer code" do
      @purchase.update!(offer_code: create(:offer_code, products: [@product], code: "sxsw", amount_cents: 100))

      expect(field_value(last_data_row, "Discount Code")).to eq("sxsw")
    end

    describe "sales tax" do
      before do
        @purchase.fee_cents = 31
      end

      it "displays (blank) when purchase is not taxable" do
        @purchase.was_purchase_taxable = false
        @purchase.save!

        row = last_data_row
        expect(field_value(row, "Subtotal ($)")).to eq("100.0")
        expect(field_value(row, "Taxes ($)")).to eq("0.0")
        expect(field_value(row, "Tax Type")).to eq("")
        expect(field_value(row, "Shipping ($)")).to eq("0.0")
        expect(field_value(row, "Sale Price ($)")).to eq("100.0")
        expect(field_value(row, "Fees ($)")).to eq("0.31")
        expect(field_value(row, "Net Total ($)")).to eq("99.69")
        expect(field_value(row, "Tax Included in Price?")).to eq(nil)
      end

      it "displays 0 for 'Is Tax Included in Price ?' when tax was excluded from purchase price" do
        @purchase.was_purchase_taxable = true
        @purchase.was_tax_excluded_from_price = true
        @purchase.tax_cents = 1_10
        @purchase.save!

        row = last_data_row
        expect(field_value(row, "Subtotal ($)")).to eq("98.9")
        expect(field_value(row, "Taxes ($)")).to eq("1.1")
        expect(field_value(row, "Shipping ($)")).to eq("0.0")
        expect(field_value(row, "Sale Price ($)")).to eq("100.0")
        expect(field_value(row, "Fees ($)")).to eq("0.31")
        expect(field_value(row, "Net Total ($)")).to eq("99.69")
        expect(field_value(row, "Tax Included in Price?")).to eq("0")
      end

      it "displays 1 for 'Is Tax Included in Price ?' when tax was not excluded from purchase price" do
        @purchase.was_purchase_taxable = true
        @purchase.was_tax_excluded_from_price = false
        @purchase.tax_cents = 1_10
        @purchase.save!

        row = last_data_row
        expect(field_value(row, "Subtotal ($)")).to eq("98.9")
        expect(field_value(row, "Taxes ($)")).to eq("1.1")
        expect(field_value(row, "Shipping ($)")).to eq("0.0")
        expect(field_value(row, "Sale Price ($)")).to eq("100.0")
        expect(field_value(row, "Fees ($)")).to eq("0.31")
        expect(field_value(row, "Net Total ($)")).to eq("99.69")
        expect(field_value(row, "Tax Included in Price?")).to eq("1")
      end

      it "has subtotal that does not include the sales tax" do
        @purchase.was_purchase_taxable = true
        @purchase.was_tax_excluded_from_price = true
        @purchase.tax_cents = 1_10
        @purchase.save!

        row = last_data_row
        expect(field_value(row, "Subtotal ($)")).to eq("98.9")
        expect(field_value(totals_row, "Subtotal ($)")).to eq("98.9")
        expect(field_value(row, "Taxes ($)")).to eq("1.1")
        expect(field_value(totals_row, "Taxes ($)")).to eq("1.1")
        expect(field_value(row, "Shipping ($)")).to eq("0.0")
        expect(field_value(totals_row, "Shipping ($)")).to eq("0.0")
        expect(field_value(row, "Sale Price ($)")).to eq("100.0")
        expect(field_value(totals_row, "Sale Price ($)")).to eq("100.0")
        expect(field_value(row, "Fees ($)")).to eq("0.31")
        expect(field_value(totals_row, "Fees ($)")).to eq("0.31")
        expect(field_value(row, "Net Total ($)")).to eq("99.69")
        expect(field_value(totals_row, "Net Total ($)")).to eq("99.69")
        expect(field_value(row, "Tax Included in Price?")).to eq("0")
      end

      it "has subtotal that does not include the tax collected by Gumroad" do
        @purchase.was_purchase_taxable = true
        @purchase.was_tax_excluded_from_price = true
        @purchase.gumroad_tax_cents = 1_80
        @purchase.save!

        row = last_data_row
        expect(field_value(row, "Subtotal ($)")).to eq("100.0")
        expect(field_value(totals_row, "Subtotal ($)")).to eq("100.0")
        expect(field_value(row, "Taxes ($)")).to eq("1.8")
        expect(field_value(totals_row, "Taxes ($)")).to eq("1.8")
        expect(field_value(row, "Shipping ($)")).to eq("0.0")
        expect(field_value(totals_row, "Shipping ($)")).to eq("0.0")
        expect(field_value(row, "Sale Price ($)")).to eq("100.0")
        expect(field_value(totals_row, "Sale Price ($)")).to eq("100.0")
        expect(field_value(row, "Fees ($)")).to eq("0.31")
        expect(field_value(totals_row, "Fees ($)")).to eq("0.31")
        expect(field_value(row, "Net Total ($)")).to eq("99.69")
        expect(field_value(totals_row, "Net Total ($)")).to eq("99.69")
        expect(field_value(row, "Tax Included in Price?")).to eq("0")
      end

      describe "tax type" do
        tax_type_test_cases = [
          { country: "IT", rate: 0.22, excluded: nil, expected_type: "VAT" },
          { country: "AU", rate: 0.10, excluded: nil, expected_type: "GST" },
          { country: "SG", rate: 0.07, excluded: nil, expected_type: "GST" },
          { country: "US", rate: 0.085, excluded: true, expected_type: "Sales tax" },
          { country: "US", rate: 0.085, excluded: false, expected_type: "Sales tax" },
          { country: nil, rate: nil, excluded: true, expected_type: "Sales tax" },
        ]

        tax_type_test_cases.each do |test_case|
          country = test_case[:country]
          rate = test_case[:rate]
          excluded = test_case[:excluded]
          expected_type = test_case[:expected_type]

          context "when country is #{country.inspect}, rate is #{rate.inspect}, and excluded is #{excluded.inspect}" do
            before do
              @purchase.update!(
                was_purchase_taxable: true,
                was_tax_excluded_from_price: excluded,
                tax_cents: 100,
                zip_tax_rate: country && create(:zip_tax_rate, country:, combined_rate: rate)
              )
            end

            it "returns #{expected_type}" do
              expect(field_value(last_data_row, "Tax Type")).to eq(expected_type)
            end
          end
        end
      end
    end

    it "includes the affiliate information" do
      @affiliate_user = create(:affiliate_user)
      @seller = create(:affiliate_user, username: "momoney")
      @product = create(:product, user: @seller)
      @direct_affiliate = create(:direct_affiliate, affiliate_user: @affiliate_user, seller: @seller, affiliate_basis_points: 3000, products: [@product])
      @purchase = create(:purchase_in_progress, seller: @seller, link: @product, purchase_state: "in_progress", affiliate: @direct_affiliate)
      @purchase.process!
      @purchase.update_balance_and_mark_successful!

      row = last_data_row
      expect(field_value(row, "Affiliate")).to eq(@affiliate_user.form_email)
      expect(field_value(row, "Affiliate commission ($)")).to eq("0.02")
    end

    it "includes the discover information" do
      @purchase.update!(was_product_recommended: true)
      expect(field_value(last_data_row, "Discover?")).to eq("1")
    end

    it "includes the full country name when purchase doesn't have shipping details" do
      create(:purchase, email: "test@gumroad.com", link: @product, zip_code: 94_103, state: "CA", country: "United States")
      create(:purchase, email: "test@gumroad.com", link: @product, ip_address: "199.241.200.176")

      rows = CSV.parse(generate_csv)
      expect(field_value(rows[1], "Country")).to eq("United States")
      expect(field_value(rows[2], "Country")).to eq("United States")
      expect(field_value(rows[3], "Country")).to eq("United States")
    end

    it "includes buyers email if buyer has an account" do
      @purchase.update!(email: "some@email.com", purchaser: create(:user, email: "some.other@email.com"))
      row = last_data_row
      expect(field_value(row, "Purchase Email")).to eq("some@email.com")
      expect(field_value(row, "Buyer Email")).to eq("some.other@email.com")
    end

    it "includes payment type" do
      @purchase.update!(card_type: "paypal")
      expect(field_value(last_data_row, "Payment Type")).to eq("PayPal")

      @purchase.update!(card_type: "mastercard")
      expect(field_value(last_data_row, "Payment Type")).to eq("Card")

      @purchase.update!(card_type: nil)
      expect(field_value(last_data_row, "Payment Type")).to eq(nil)
    end

    it "includes PayPal fields only for PayPal marketplace sales" do
      @purchase.update!(
        card_type: "mastercard",
        processor_fee_cents: 12,
        processor_fee_cents_currency: "eur"
      )
      expect(field_value(last_data_row, "PayPal Transaction ID")).to be_nil
      expect(field_value(last_data_row, "PayPal Fee Amount")).to be_nil
      expect(field_value(last_data_row, "PayPal Fee Currency")).to be_nil

      @purchase.update!(card_type: "paypal")
      expect(field_value(last_data_row, "PayPal Transaction ID")).to be_nil
      expect(field_value(last_data_row, "PayPal Fee Amount")).to be_nil
      expect(field_value(totals_row, "PayPal Fee Amount")).to eq("0.0")
      expect(field_value(last_data_row, "PayPal Fee Currency")).to be_nil

      @purchase.update!(card_type: "paypal", paypal_order_id: "someOrderId", stripe_transaction_id: "PayPalTx123")
      expect(field_value(last_data_row, "PayPal Transaction ID")).to eq("PayPalTx123")
      expect(field_value(last_data_row, "PayPal Fee Amount")).to eq("0.12")
      expect(field_value(totals_row, "PayPal Fee Amount")).to eq("0.12")
      expect(field_value(last_data_row, "PayPal Fee Currency")).to eq("eur")
    end

    it "includes PayPal fields with fee amount in USD" do
      @purchase.update!(
        card_type: "mastercard",
        processor_fee_cents: 13,
        processor_fee_cents_currency: "usd"
      )
      @purchase.update!(card_type: "paypal", paypal_order_id: "someOrderId", stripe_transaction_id: "PayPalTx123")
      expect(field_value(last_data_row, "PayPal Transaction ID")).to eq("PayPalTx123")
      expect(field_value(last_data_row, "PayPal Fee Amount")).to eq("0.13")
      expect(field_value(last_data_row, "PayPal Fee Currency")).to eq("usd")
    end

    it "includes PayPal fields with fee amount in GBP" do
      @purchase.update!(
        card_type: "mastercard",
        processor_fee_cents: 14,
        processor_fee_cents_currency: "gbp"
      )
      @purchase.update!(card_type: "paypal", paypal_order_id: "someOrderId", stripe_transaction_id: "PayPalTx123")
      expect(field_value(last_data_row, "PayPal Transaction ID")).to eq("PayPalTx123")
      expect(field_value(last_data_row, "PayPal Fee Amount")).to eq("0.14")
      expect(field_value(last_data_row, "PayPal Fee Currency")).to eq("gbp")
    end

    it "includes Stripe fields only for Stripe Connect sales", :vcr do
      expect(field_value(last_data_row, "Stripe Transaction ID")).to be_nil
      expect(field_value(last_data_row, "Stripe Fee Amount")).to be_nil
      expect(field_value(last_data_row, "Stripe Fee Currency")).to be_nil

      @purchase.update!(
        merchant_account_id: create(:merchant_account_paypal).id,
        paypal_order_id: "someOrderId",
        processor_fee_cents: 12,
        processor_fee_cents_currency: "eur",
        stripe_transaction_id: "PayPalTx123"
      )
      expect(field_value(last_data_row, "Stripe Transaction ID")).to be_nil
      expect(field_value(last_data_row, "Stripe Fee Amount")).to be_nil
      expect(field_value(last_data_row, "Stripe Fee Currency")).to be_nil

      @purchase.update!(
        merchant_account_id: create(:merchant_account_stripe).id,
        processor_fee_cents: 12,
        processor_fee_cents_currency: "eur",
        stripe_transaction_id: "ch_12345"
      )
      expect(field_value(last_data_row, "Stripe Transaction ID")).to be_nil
      expect(field_value(last_data_row, "Stripe Fee Amount")).to be_nil
      expect(field_value(last_data_row, "Stripe Fee Currency")).to be_nil

      @purchase.update!(
        merchant_account_id: create(:merchant_account_stripe_connect).id,
        processor_fee_cents: 12,
        processor_fee_cents_currency: "eur",
        stripe_transaction_id: "ch_12345"
      )
      expect(field_value(last_data_row, "Stripe Transaction ID")).to eq("ch_12345")
      expect(field_value(last_data_row, "Stripe Fee Amount")).to eq("0.12")
      expect(field_value(totals_row, "Stripe Fee Amount")).to eq("0.12")
      expect(field_value(last_data_row, "Stripe Fee Currency")).to eq("eur")
    end

    it "includes a field indicating if the purchase was purchasing power parity discounted" do
      expect(field_value(last_data_row, "Purchasing Power Parity Discounted?")).to eq("0")
      @purchase.update!(is_purchasing_power_parity_discounted: true)
      expect(field_value(last_data_row, "Purchasing Power Parity Discounted?")).to eq("1")
    end

    it "includes a field indicating if the purchase was upsold" do
      expect(field_value(last_data_row, "Upsold?")).to eq("0")
      create(:upsell_purchase, purchase: @purchase, upsell: create(:upsell, seller: @seller, product: @product, cross_sell: true))
      expect(field_value(last_data_row, "Upsold?")).to eq("1")
    end

    it "generates csv with default purchase fields and extra purchase fields" do
      # We name a field "Order number" to check that a custom field can have the same name as a default field name
      create(:purchase_custom_field, name: "Age", value: "30", purchase: @purchase)
      create(:purchase_custom_field, name: "Order Number", value: "O123", purchase: @purchase)
      # We check that the custom fields of the represented products are present, even if the purchases don't set them
      @product.custom_fields << [create(:custom_field, name: "Age"), create(:custom_field, name: "Size")]

      csv = generate_csv
      rows = CSV.parse(csv)
      headers, row = rows.first, rows[rows.size - 2]

      expect(headers).to eq(described_class::PURCHASE_FIELDS + ["Age", "Order Number", "Size"])
      expect(headers).to include("Tax Type")

      expect(headers.count("Order Number")).to eq(2)
      native_field_index = headers.index("Order Number")
      expect(row.fetch(native_field_index)).to eq(@purchase.external_id_numeric.to_s)
      custom_field_index = headers.rindex("Order Number")
      expect(row.fetch(custom_field_index)).to eq("O123")

      expect(row.fetch(headers.index("Age"))).to eq("30")
      expect(row.fetch(headers.index("Size"))).to eq(nil)
    end

    it "raises error if a value is not JSON safe (type other than String, Number, Array, Hash, Boolean, NilClass)" do
      expect { generate_csv }.not_to raise_error

      allow_any_instance_of(Purchase).to receive(:license_key).and_return(Time.now.utc)
      expect { generate_csv }.to raise_error(StandardError, /not JSON safe/)
      allow_any_instance_of(Purchase).to receive(:license_key).and_return(Time.zone.now)
      expect { generate_csv }.to raise_error(StandardError, /not JSON safe/)
      allow_any_instance_of(Purchase).to receive(:license_key).and_return(Date.today)
      expect { generate_csv }.to raise_error(StandardError, /not JSON safe/)
    end

    it "includes licence key" do
      @product.update!(is_licensed: true)
      @purchase.create_license!

      expect(@purchase.license_key).to be_present
      expect(field_value(last_data_row, "License Key")).to eq(@purchase.license_key)
    end

    it "includes licence key belonging to the giftee" do
      @product.update!(is_licensed: true)
      @purchase.update!(is_gift_sender_purchase: true)
      giftee_purchase = create(:purchase, :gift_receiver, link: @product)
      create(:gift, link: @product, gifter_purchase: @purchase, giftee_purchase:)
      giftee_purchase.create_license!

      expect(@purchase.license_key).to be_blank
      expect(giftee_purchase.license_key).to be_present
      expect(field_value(last_data_row, "License Key")).to eq(giftee_purchase.license_key)
    end

    it "includes license key activation count" do
      @product.update!(is_licensed: true)
      @purchase.create_license!

      expect(field_value(last_data_row, "License Key Activation Count")).to eq("0")

      @purchase.license.update!(uses: 5)
      expect(field_value(last_data_row, "License Key Activation Count")).to eq("5")
    end

    it "includes license key activation count for giftee" do
      @product.update!(is_licensed: true)
      @purchase.update!(is_gift_sender_purchase: true)
      giftee_purchase = create(:purchase, :gift_receiver, link: @product)
      create(:gift, link: @product, gifter_purchase: @purchase, giftee_purchase:)
      giftee_purchase.create_license!
      giftee_purchase.license.update!(uses: 3)

      expect(field_value(last_data_row, "License Key Activation Count")).to eq("3")
    end

    it "shows nil for license key activation count when no license exists" do
      expect(field_value(last_data_row, "License Key Activation Count")).to be_nil
    end

    it "shows whether the purchase is associated to a sent abandoned cart email" do
      expect(field_value(last_data_row, "Sent Abandoned Cart Email?")).to eq("0")
      cart = create(:cart, order: create(:order, purchases: [@purchase]))
      create(:sent_abandoned_cart_email, cart:) # for a different seller's product
      expect(field_value(last_data_row, "Sent Abandoned Cart Email?")).to eq("0")
      workflow = create(:abandoned_cart_workflow, seller: @seller)
      create(:sent_abandoned_cart_email, cart:, installment: workflow.installments.sole)
      expect(field_value(last_data_row, "Sent Abandoned Cart Email?")).to eq("1")
    end

    it "includes access revoked status" do
      expect(field_value(last_data_row, "Access Revoked?")).to eq("0")

      @purchase.update!(is_access_revoked: true)
      expect(field_value(last_data_row, "Access Revoked?")).to eq("1")
    end

    context "when the purchase has a tip" do
      before do
        create(:tip, purchase: @purchase, value_usd_cents: 100, created_at: 2.minutes.ago)
        create(:tip, purchase: create(:purchase, link: @product, seller: @seller), value_usd_cents: 450, created_at: 1.minute.ago)
      end

      it "includes the tip amount in USD" do
        expect(field_value(last_data_row, "Tip ($)")).to eq("4.5")
        expect(field_value(totals_row, "Tip ($)")).to eq("5.5")
      end
    end

    context "when the purchase has no tip" do
      it "shows 0 for the tip amount" do
        expect(field_value(last_data_row, "Tip ($)")).to eq("0.0")
        expect(field_value(totals_row, "Tip ($)")).to eq("0.0")
      end
    end

    describe "UTM parameters" do
      context "when the purchase was not driven by a UTM link" do
        it "includes blank values for UTM parameters" do
          expect(field_value(last_data_row, "UTM Source")).to be_nil
          expect(field_value(last_data_row, "UTM Medium")).to be_nil
          expect(field_value(last_data_row, "UTM Campaign")).to be_nil
          expect(field_value(last_data_row, "UTM Term")).to be_nil
          expect(field_value(last_data_row, "UTM Content")).to be_nil
        end
      end

      context "when the purchase was driven by a UTM link" do
        it "includes the UTM parameters" do
          utm_link = create(:utm_link, utm_source: "twitter", utm_medium: "social", utm_campaign: "campaign", utm_term: "gumroad", utm_content: "hello-world")
          create(:utm_link_driven_sale, utm_link:, purchase: @purchase)

          expect(field_value(last_data_row, "UTM Source")).to eq("twitter")
          expect(field_value(last_data_row, "UTM Medium")).to eq("social")
          expect(field_value(last_data_row, "UTM Campaign")).to eq("campaign")
          expect(field_value(last_data_row, "UTM Term")).to eq("gumroad")
          expect(field_value(last_data_row, "UTM Content")).to eq("hello-world")
        end
      end
    end
  end

  def field_index(name)
    described_class::PURCHASE_FIELDS.index(name)
  end

  def field_value(row, name)
    row.fetch(field_index(name))
  end

  def generate_csv(purchases = @seller.sales.where(purchase_state: Purchase::NON_GIFT_SUCCESS_STATES))
    described_class.new(purchases).perform.read
  end

  def last_data_row
    rows = CSV.parse(generate_csv)
    rows[rows.size - 2] # last row has totals
  end

  def totals_row
    rows = CSV.parse(generate_csv)
    rows.last
  end
end
