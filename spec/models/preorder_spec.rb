# frozen_string_literal: true

require "spec_helper"

describe Preorder, :vcr do
  before do
    $currency_namespace = Redis::Namespace.new(:currencies, redis: $redis)
  end

  describe "mobile_json_data" do
    it "returns proper json for a preorder without a url redirect" do
      good_card = build(:chargeable)
      link = create(:product, price_cents: 600, is_in_preorder_state: true)
      preorder_product = create(:preorder_link, link:)
      authorization_purchase = build(:purchase, link:, chargeable: good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      json_hash = preorder.mobile_json_data
      %w[name description unique_permalink created_at updated_at].each do |attr|
        attr = attr.to_sym unless %w[name description unique_permalink].include?(attr)
        expect(json_hash[attr]).to eq link.send(attr)
      end
      expect(json_hash[:preview_url]).to eq ""
      expect(json_hash[:creator_name]).to eq link.user.username
      expect(json_hash[:preview_oembed_url]).to eq ""
      expect(json_hash[:preview_height]).to eq 0
      expect(json_hash[:preview_width]).to eq 0
      expect(json_hash[:url_redirect_external_id]).to eq nil
      expect(json_hash[:file_data]).to eq nil
      expect(json_hash[:purchased_at]).to eq authorization_purchase.created_at
      preorder_data = { external_id: preorder.external_id, release_at: preorder_product.release_at }
      expect(json_hash[:preorder_data]).to eq preorder_data
    end

    it "returns proper json for a preorder with a url redirect post charge" do
      travel_to(Time.current) do
        good_card = build(:chargeable)
        link = create(:product, price_cents: 600, is_in_preorder_state: true)
        link.product_files << create(
          :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/6996320f4de6424990904fcda5808cef/original/Don&amp;#39;t Stop.mp3"
        )
        link.product_files << create(
          :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/a1a5b8c8c38749e2b3cb27099a817517/original/Alice&#39;s Adventures in Wonderland.pdf"
        )
        preorder_link = create(:preorder_link, link:, release_at: 2.days.from_now)
        authorization_purchase = build(:purchase, link:, chargeable: good_card, purchase_state: "in_progress", is_preorder_authorization: true)
        preorder = preorder_link.build_preorder(authorization_purchase)
        preorder.authorize!
        expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
        preorder.mark_authorization_successful
        expect(preorder.state).to eq "authorization_successful"
        link.is_in_preorder_state = false
        link.save!
        purchase = preorder.charge!
        json_hash = preorder.mobile_json_data
        %w[name description unique_permalink created_at updated_at].each do |attr|
          attr = attr.to_sym unless %w[name description unique_permalink].include?(attr)
          expect(json_hash[attr]).to eq link.send(attr)
        end
        expect(json_hash[:preview_url]).to eq ""
        expect(json_hash[:creator_name]).to eq link.user.username
        expect(json_hash[:preview_oembed_url]).to eq ""
        expect(json_hash[:preview_height]).to eq 0
        expect(json_hash[:preview_width]).to eq 0
        expect(json_hash[:url_redirect_external_id]).to eq purchase.url_redirect.external_id
        expect(json_hash[:file_data].map { |product_file| product_file[:name] }).to eq ["Don&amp;#39;t Stop.mp3", "Alice&#39;s Adventures in Wonderland.pdf"]
        expect(json_hash[:purchased_at].to_i).to eq authorization_purchase.created_at.to_i
        expect(json_hash[:preorder_data]).to eq nil
      end
    end
  end

  describe "authorize! and charge!" do
    before do
      @product = create(:product, price_cents: 600, is_in_preorder_state: false)
      @preorder_product = create(:preorder_product_with_content, link: @product)
      @preorder_product.update(release_at: Time.current) # bypassed the creation validation
      @good_card = build(:chargeable)
      @bad_card = build(:chargeable_decline)
      @incorrect_cvc_card = build(:chargeable_decline_cvc_check_fails)
      @good_card_but_cant_charge = build(:chargeable, card: StripePaymentMethodHelper.success_charge_decline)
    end

    after do
      # delete this entry so that the subsequent specs don't read the value set by these specs.
      $currency_namespace.set("JPY",  nil)
    end

    it "marks the authorization purchase and preorder as invalid because of incorrect cvc" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @incorrect_cvc_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.errors).to be_present
      expect(preorder.authorization_purchase.errors).to be_present
      expect(preorder.authorization_purchase.stripe_error_code).to eq "incorrect_cvc"

      preorder.mark_authorization_failed
      expect(preorder.state).to eq "authorization_failed"
    end

    it "creates both the authorization purchase and the main purchase and their states is properly set" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"

      preorder.mark_authorization_successful
      expect(preorder.state).to eq "authorization_successful"

      preorder.charge!
      purchase = preorder.purchases.last
      expect(purchase.purchase_state).to eq "successful"
      expect(purchase.card_visual).to eq "**** **** **** 4242"
      preorder.mark_charge_successful
      expect(preorder.state).to eq "charge_successful"
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_concluded_successfully"
      expect(preorder.reload.credit_card).to be_present
    end

    it "creates both the authorization purchase and the main purchase and their states is properly set - for PayPal as a chargeable" do
      authorization_purchase = build(:purchase, link: @product, chargeable: build(:paypal_chargeable), purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"

      preorder.mark_authorization_successful
      expect(preorder.state).to eq "authorization_successful"

      preorder.charge!
      purchase = preorder.purchases.last
      expect(purchase.purchase_state).to eq "successful"
      expect(purchase.card_visual).to eq "jane.doe@example.com"
      preorder.mark_charge_successful
      expect(preorder.state).to eq "charge_successful"
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_concluded_successfully"
      expect(preorder.reload.credit_card).to be_present
    end

    describe "handling of unexpected errors", :vcr do
      context "when a rate limit error occurs" do
        it "does not leave the purchase in in_progress state" do
          expect do
            expect do
              expect do
                authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
                preorder = @preorder_product.build_preorder(authorization_purchase)
                preorder.authorize!
                preorder.mark_authorization_successful

                expect(Stripe::PaymentIntent).to receive(:create).and_raise(Stripe::RateLimitError)
                preorder.charge!
              end.to raise_error(ChargeProcessorError)
            end.to change { Purchase.failed.count }.by(1)
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when a generic Stripe error occurs" do
        it "does not leave the purchase in in_progress state" do
          expect do
            authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
            preorder = @preorder_product.build_preorder(authorization_purchase)
            preorder.authorize!
            preorder.mark_authorization_successful

            expect(Stripe::PaymentIntent).to receive(:create).and_raise(Stripe::IdempotencyError)
            purchase = preorder.charge!
            expect(purchase.purchase_state).to eq("failed")
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when a generic Braintree error occurs" do
        it "does not leave the purchase in in_progress state" do
          expect do
            authorization_purchase = build(:purchase, link: @product, chargeable: build(:paypal_chargeable), purchase_state: "in_progress", is_preorder_authorization: true)
            preorder = @preorder_product.build_preorder(authorization_purchase)
            preorder.authorize!
            preorder.mark_authorization_successful

            expect(Braintree::Transaction).to receive(:sale).and_raise(Braintree::BraintreeError)
            purchase = preorder.charge!
            expect(purchase.purchase_state).to eq("failed")
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when a PayPal connection error occurs" do
        it "does not leave the purchase in in_progress state" do
          create(:merchant_account_paypal, user: @product.user, charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")

          expect do
            authorization_purchase = build(:purchase, link: @product, chargeable: build(:native_paypal_chargeable), purchase_state: "in_progress", is_preorder_authorization: true)
            preorder = @preorder_product.build_preorder(authorization_purchase)
            preorder.authorize!
            preorder.mark_authorization_successful

            expect_any_instance_of(PayPal::PayPalHttpClient).to receive(:execute).and_raise(PayPalHttp::HttpError.new(418, OpenStruct.new(details: [OpenStruct.new(description: "IO Error")]), nil))
            purchase = preorder.charge!
            expect(purchase.purchase_state).to eq("failed")
          end.not_to change { Purchase.in_progress.count }
        end
      end

      context "when unexpected runtime error occurs mid purchase" do
        it "does not leave the purchase in in_progress state" do
          expect do
            expect do
              expect do
                authorization_purchase = build(:purchase, link: @product, chargeable: build(:paypal_chargeable), purchase_state: "in_progress", is_preorder_authorization: true)
                preorder = @preorder_product.build_preorder(authorization_purchase)
                preorder.authorize!
                preorder.mark_authorization_successful

                expect_any_instance_of(Purchase).to receive(:charge!).and_raise(RuntimeError)
                preorder.charge!
              end.to raise_error(RuntimeError)
            end.to change { Purchase.failed.count }.by(1)
          end.not_to change { Purchase.in_progress.count }
        end
      end
    end

    it "sends the proper preorder emails" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(ContactingCreatorMailer).to receive(:notify).and_return(mail_double)
      expect(CustomerMailer).to receive(:preorder_receipt).and_return(mail_double)
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful
    end

    it "sends the proper preorder emails for test preorders" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(ContactingCreatorMailer).to receive(:notify).and_return(mail_double)
      expect(CustomerMailer).to receive(:preorder_receipt).and_return(mail_double)
      expect(CustomerMailer).to_not receive(:receipt)
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress",
                                                purchaser: @product.user, seller: @product.user, is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_test_authorization_successful!
    end

    it "does not create a url redirect on successful authorization" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful

      expect(preorder.url_redirect).to_not be_present
    end

    it "creates both the authorization purchase (successful) and the main purchase (failed)" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card_but_cant_charge,
                                                purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"

      preorder.mark_authorization_successful
      expect(preorder.state).to eq "authorization_successful"

      preorder.charge!
      expect(preorder.purchases.last.purchase_state).to eq "failed"
      expect(preorder.purchases.last.stripe_error_code).to eq "card_declined_generic_decline"

      preorder.mark_cancelled
      expect(preorder.state).to eq "cancelled"
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_concluded_unsuccessfully"
    end

    it "enqueues activate integrations worker on successful charge" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful
      preorder.charge!
      purchase = preorder.purchases.last

      expect(purchase.reload.purchase_state).to eq "successful"
      expect(ActivateIntegrationsWorker).to have_enqueued_sidekiq_job(preorder.purchases.last.id)
    end

    it "does not enqueue activate integrations worker if charge fails" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card_but_cant_charge,
                                                purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful
      preorder.charge!

      expect(preorder.purchases.last.purchase_state).to eq "failed"
      expect(ActivateIntegrationsWorker.jobs.size).to eq(0)
    end

    it "does not charge the preorder if a purchase is in progress" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"

      preorder.mark_authorization_successful
      expect(preorder.state).to eq "authorization_successful"

      create(:purchase, link: @product, preorder:, chargeable: @good_card, purchase_state: "in_progress")

      expect do
        preorder.charge!
      end.not_to change(Purchase, :count)
    end

    it "does not charge the same preorder twice" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"

      preorder.mark_authorization_successful
      expect(preorder.state).to eq "authorization_successful"

      preorder.charge!
      purchase = preorder.purchases.last
      expect(purchase.purchase_state).to eq "successful"
      expect(purchase.card_visual).to eq "**** **** **** 4242"

      travel 1.hour # skipping the double charge protection

      expect do
        preorder.charge!
      end.not_to change(Purchase, :count)
    end

    it "properly cancels the preorder and mark its auth purchase as concluded" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"

      preorder.mark_authorization_successful
      expect(preorder.state).to eq "authorization_successful"

      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(ContactingCreatorMailer).to receive(:preorder_cancelled).and_return(mail_double)
      expect(CustomerLowPriorityMailer).to receive(:preorder_cancelled).and_return(mail_double)

      preorder.mark_cancelled

      expect(preorder.state).to eq "cancelled"
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_concluded_unsuccessfully"
      expect(preorder.reload.credit_card).to be_present
    end

    it "applies the offer code that was used at the time of the preorder" do
      offer_code = create(:offer_code, products: [@product], code: "sxsw", amount_cents: 200)
      authorization_purchase = build(:purchase, link: @product, offer_code:, discount_code: offer_code.code,
                                                chargeable: @good_card, purchase_state: "in_progress", referrer: "thefacebook.com",
                                                is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 400

      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(ContactingCreatorMailer).to receive(:notify).and_return(mail_double)
      preorder.mark_authorization_successful

      expect(ContactingCreatorMailer).to_not receive(:notify)

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.offer_code).to eq offer_code
      expect(charge_purchase.price_cents).to eq 400
      expect(charge_purchase.referrer).to eq "thefacebook.com"
    end

    it "applies the variants that were used at the time of the preorder" do
      category = create(:variant_category, title: "sizes", link: @product)
      variant = create(:variant, name: "small", price_difference_cents: 300, variant_category: category)
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      authorization_purchase.variant_attributes << variant
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 900

      preorder.mark_authorization_successful

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.variant_attributes).to include variant
      expect(charge_purchase.price_cents).to eq 900
    end

    it "applies the quantity that was used at the time of the preorder" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true, quantity: 3)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 1800

      preorder.mark_authorization_successful

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.quantity).to eq 3
      expect(charge_purchase.price_cents).to eq 1800
    end

    it "applies the name, address, shipping_cents, etc. that were used at the time of the preorder" do
      @product.update!(require_shipping: true, is_physical: true)
      @product.shipping_destinations << create(:shipping_destination, country_code: Compliance::Countries::USA.alpha2)

      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress",
                                                is_preorder_authorization: true, zip_code: "94102", city: "sf",
                                                full_name: "gum stein", street_address: "here", country: "United States", state: "ca")
      authorization_purchase.purchase_custom_fields << [
        build(:purchase_custom_field, name: "height", value: "tall"),
        build(:purchase_custom_field, name: "waist", value: "fat")
      ]
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful!

      # Set a new non-zero shipping price
      @product.shipping_destinations.first.update!(one_item_rate_cents: 500, multiple_items_rate_cents: 500)

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.purchase_custom_fields.pluck(:name, :value, :field_type)).to eq authorization_purchase.purchase_custom_fields.pluck(:name, :value, :field_type)
      expect(charge_purchase.custom_fields).to eq authorization_purchase.custom_fields
      expect(charge_purchase.full_name).to eq authorization_purchase.full_name
      expect(charge_purchase.street_address).to eq authorization_purchase.street_address
      expect(charge_purchase.country).to eq authorization_purchase.country
      expect(charge_purchase.state).to eq authorization_purchase.state
      expect(charge_purchase.zip_code).to eq authorization_purchase.zip_code
      expect(charge_purchase.city).to eq authorization_purchase.city
      expect(charge_purchase.shipping_cents).to eq(0)
    end

    it "charges the preorder when the product requires shipping but the auth purchase doesn't have shipping info \
        (the product did not require shipping at the time of auth)" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress",
                                                is_preorder_authorization: true, full_name: "gum stein")
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful

      @product.update(require_shipping: true)

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.full_name).to eq authorization_purchase.full_name
      expect(charge_purchase.street_address).to eq authorization_purchase.street_address
      expect(charge_purchase.country).to eq authorization_purchase.country
      expect(charge_purchase.state).to eq authorization_purchase.state
      expect(charge_purchase.zip_code).to eq authorization_purchase.zip_code
      expect(charge_purchase.city).to eq authorization_purchase.city
    end

    it "transfers VAT ID and elected tax country from the authorization to the actual charge" do
      create(:zip_tax_rate, country: "IT", zip_code: nil, state: nil, combined_rate: 0.22, is_seller_responsible: false)

      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress",
                                                is_preorder_authorization: true, full_name: "gum stein",
                                                ip_address: "2.47.255.255", country: "Italy")
      authorization_purchase.business_vat_id = "IE6388047V"
      authorization_purchase.sales_tax_country_code_election = "IT"
      authorization_purchase.process!
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.purchase_sales_tax_info.business_vat_id).to eq "IE6388047V"
      expect(charge_purchase.purchase_sales_tax_info.elected_country_code).to eq "IT"
      expect(charge_purchase.total_transaction_cents).to eq 600
      expect(charge_purchase.gumroad_tax_cents).to eq 0
    end

    it "does not charge the card if the preorder is free" do
      expect(Stripe::PaymentIntent).to_not receive(:create)
      @product.update_attribute(:price_cents, 0)

      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 0

      preorder.mark_authorization_successful

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.price_cents).to eq 0
    end

    it "charges the card if the preorder is free but has a variant with a price" do
      @product.update_attribute(:price_cents, 0)
      category = create(:variant_category, title: "sizes", link: @product)
      variant = create(:variant, name: "small", price_difference_cents: 300, variant_category: category)
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      authorization_purchase.variant_attributes << variant
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 300

      preorder.mark_authorization_successful

      preorder.charge!
      charge_purchase = preorder.purchases.last.reload
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.variant_attributes).to include variant
      expect(charge_purchase.price_cents).to eq 300
    end

    it "charges the card the right amount based on the exchange rate at the time of the charge" do
      @product.update!(price_currency_type: "jpy", price_cents: 600)
      $currency_namespace.set("JPY",  95)
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 632 # 600 yens in cents

      preorder.mark_authorization_successful

      $currency_namespace.set("JPY", 100)
      preorder.charge!
      charge_purchase = preorder.purchases.last.reload
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.price_cents).to eq 600 # 600 yens in cents based on the new rate
    end

    it "charges the card the right amount based on the custom price the buyer entered at preorder time" do
      @product.update_attribute(:customizable_price, true)
      authorization_purchase = build(:purchase, link: @product, perceived_price_cents: 7_00, chargeable: @good_card,
                                                purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 700

      preorder.mark_authorization_successful

      preorder.charge!
      charge_purchase = preorder.purchases.last.reload
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.price_cents).to eq 700
    end

    it "charges the card the right amount based on the custom price the buyer entered at preorder time - non USD" do
      @product.update!(
        price_currency_type: "jpy",
        price_cents: 600,
        customizable_price: true
      )
      $currency_namespace.set("JPY",  90)
      authorization_purchase = build(:purchase, link: @product, perceived_price_cents: 700, chargeable: @good_card,
                                                purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 778

      preorder.mark_authorization_successful

      $currency_namespace.set("JPY",  100)
      preorder.charge!
      charge_purchase = preorder.purchases.last.reload
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.price_cents).to eq 700
    end

    it "does not count the charge purchase towards the offer code limit" do
      offer_code = create(:offer_code, products: [@product], code: "sxsw", amount_cents: 200, max_purchase_count: 1)
      authorization_purchase = build(:purchase, link: @product, offer_code:, discount_code: offer_code.code, chargeable: @good_card,
                                                purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 400

      preorder.mark_authorization_successful

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.offer_code).to eq offer_code
      expect(charge_purchase.price_cents).to eq 400

      authorization_purchase = build(:purchase, link: @product, offer_code:, discount_code: offer_code.code,
                                                chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.errors).to be_present
      expect(preorder.authorization_purchase.error_code).to eq("offer_code_sold_out")
    end

    it "does not count the charge purchase towards the variant quantity limit" do
      category = create(:variant_category, title: "sizes", link: @product)
      variant = create(:variant, name: "small", price_difference_cents: 300, variant_category: category, max_purchase_count: 1)
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      authorization_purchase.variant_attributes << variant
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 900

      preorder.mark_authorization_successful

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.variant_attributes).to include variant
      expect(charge_purchase.price_cents).to eq 900
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      authorization_purchase.variant_attributes << variant
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.errors).to be_present
      preorder.mark_authorization_failed!
    end

    it "does not count the charge purchase towards the product quantity limit" do
      @product.update_attribute(:max_purchase_count, 1)
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 600

      preorder.mark_authorization_successful

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.price_cents).to eq 600

      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      expect(preorder.errors).to be_present
      preorder.mark_authorization_failed!
    end

    it "charges the buyer the amount equal to the price at the time of the preorder" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful

      @product.update(price_cents: 800)

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.price_cents).to eq 600
    end

    it "charges the buyer the amount equal to the non-integer price at the time of the preorder" do
      @product.update(price_cents: 599)
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.price_cents).to eq 599
    end

    it "charges the buyer the amount equal to the price (in yens) at the time of the preorder" do
      @product.update!(price_currency_type: "jpy", price_cents: 600)
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful

      @product.update(price_cents: 1600)
      $currency_namespace.set("JPY", 50)

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.price_cents).to eq 1200 # 600 yens in usd cents based on the new rate
    end

    it "charges the buyer the right amount regardless of the variant price changes" do
      category = create(:variant_category, title: "sizes", link: @product)
      variant = create(:variant, name: "small", price_difference_cents: 300, variant_category: category)
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      authorization_purchase.variant_attributes << variant
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful

      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.price_cents).to eq 900

      variant.update!(price_difference_cents: 200)

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.variant_attributes).to include variant
      expect(charge_purchase.price_cents).to eq 900
    end

    it "charges the buyer even if the product is unpublished" do
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful

      @product.update_attribute(:purchase_disabled_at, Time.current)

      preorder.charge!
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
    end

    it "does not create a license for the preorder authorization but it should when the preorder concludes successfully" do
      @product.is_licensed = true
      @product.save!
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful
      expect(authorization_purchase.reload.license).to be(nil)
      expect(License.count).to eq 0
      @product.update_attribute(:purchase_disabled_at, Time.current)

      preorder.charge!
      expect(License.count).to eq 1
      charge_purchase = preorder.purchases.last
      expect(charge_purchase.purchase_state).to eq "successful"
      expect(charge_purchase.license).to_not be(nil)
    end

    it "associates the charge to the affiliate if the authorization was associated to the affiliate" do
      @product.update!(price_cents: 10_00)
      affiliate_user = create(:affiliate_user)
      direct_affiliate = create(:direct_affiliate, affiliate_user:, seller: @product.user, affiliate_basis_points: 1000, products: [@product])
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true,
                                                affiliate: direct_affiliate)

      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!

      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      expect(preorder.authorization_purchase.affiliate_credit).to be_nil # balances aren't affected during pre-order auth.
      expect(preorder.authorization_purchase.affiliate).to eq(direct_affiliate)

      preorder.mark_authorization_successful
      expect(preorder.state).to eq "authorization_successful"

      purchase = preorder.charge!
      expect(purchase.purchase_state).to eq "successful"
      expect(purchase.affiliate_credit_cents).to eq(79)
      expect(purchase.affiliate).to eq(direct_affiliate)
      expect(purchase.affiliate_credit.affiliate).to eq(direct_affiliate)
      expect(@product.user.unpaid_balance_cents).to eq(712) # 1000c (price) - 79c (affiliate fee) - 9/10th of the fee (100c (10% flat fee) - 50c - 29 (2.9% cc fee) - 30c (fixed cc fee))
      expect(affiliate_user.unpaid_balance_cents).to eq(79)
    end

    it "has was_product_recommended be true for purchase, charge the extra fee, and update recommended_purchase_info" do
      @product.update!(price_cents: 10_00)
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true,
                                                was_product_recommended: true)

      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!

      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_authorization_successful"
      rec_purchase_info = create(:recommended_purchase_info, purchase: preorder.authorization_purchase, recommended_link: @product)
      preorder.mark_authorization_successful
      expect(preorder.state).to eq "authorization_successful"

      purchase = preorder.charge!
      expect(purchase.purchase_state).to eq "successful"
      expect(purchase.was_product_recommended).to eq(true)
      expect(purchase.fee_cents).to eq(209) # 100c (10% flat fee) + 50c + 29c (2.9% cc fee) + 30c (fixed cc fee)
      expect(purchase.discover_fee_per_thousand).to eq(100)
      expect(rec_purchase_info.purchase).to eq(purchase)
      expect(@product.user.unpaid_balance_cents).to eq(791)
    end
  end
end
