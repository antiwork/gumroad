# frozen_string_literal: false

require "spec_helper"
require "shared_examples/authorize_called"

include CurrencyHelper

describe OrdersController, :vcr do
  before do
    cookies[:_gumroad_guid] = SecureRandom.uuid
  end

  describe "POST create" do
    let(:seller_1) { create(:user) }
    let(:seller_2) { create(:user) }
    let(:price_1) { 5_00 }
    let(:price_2) { 10_00 }
    let(:price_3) { 10_00 }
    let(:price_4) { 10_00 }
    let(:price_5) { 10_00 }
    let(:product_1) { create(:product, user: seller_1, price_cents: price_1) }
    let(:product_2) { create(:product, user: seller_1, price_cents: price_2) }
    let(:product_3) { create(:product, user: seller_2, price_cents: price_3) }
    let(:product_4) { create(:product, user: seller_2, price_cents: price_4) }
    let(:product_5) { create(:product, user: seller_2, price_cents: price_5, discover_fee_per_thousand: 300) }

    let(:payment_params) { StripePaymentMethodHelper.success.to_stripejs_params }
    let(:sca_payment_params) { StripePaymentMethodHelper.success_with_sca.to_stripejs_params }
    let(:pp_native_payment_params) do
      {
        billing_agreement_id: "B-1S519614KK328642S"
      }
    end
    let(:common_purchase_params_without_payment) do
      {
        email: "buyer@gumroad.com",
        cc_zipcode_required: "false",
        cc_zipcode: "12345",
        purchase: {
          full_name: "Edgar Gumstein",
          street_address: "123 Gum Road",
          country: "US",
          state: "CA",
          city: "San Francisco",
          zip_code: "94117"
        }
      }
    end
    let(:common_purchase_params) do
      common_purchase_params_without_payment.merge(payment_params)
    end
    let(:common_purchase_params_with_sca) do
      common_purchase_params_without_payment.merge(sca_payment_params)
    end
    let(:common_purchase_params_with_native_pp) do
      common_purchase_params_without_payment.merge(pp_native_payment_params)
    end

    context "single purchase" do
      let(:single_purchase_params) do
        {
          line_items: [{
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            perceived_price_cents: price_1,
            quantity: 1
          }]
        }.merge(common_purchase_params)
      end

      it "creates an order, a charge, and a purchase" do
        expect do
          expect do
            expect do
              post :create, params: single_purchase_params

              expect(response.parsed_body["success"]).to be(true)
              expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(true)
              expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)
            end.to change(Purchase.successful, :count).by(1)
          end.to change(Charge, :count).by(1)
        end.to change(Order, :count).by(1)

        order = Order.last
        charge = Charge.last
        purchase = Purchase.last
        expect(order.charges).to eq([charge])
        expect(order.purchases).to eq([purchase])
        expect(charge.purchases).to eq([purchase])
        expect(purchase.is_part_of_combined_charge?).to be true
        expect(purchase.charge.amount_cents).to eq(purchase.total_transaction_cents)
        expect(purchase.charge.gumroad_amount_cents).to eq(purchase.fee_cents)
        expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge.id)
      end

      context "when purchase fails" do
        let(:payment_params) { StripePaymentMethodHelper.decline.to_stripejs_params }

        it "responds with success: false for specific line item" do
          post :create, params: single_purchase_params

          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(false)
          expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)
        end

        it "creates an order and a failed purchase and a charge if purchase failed after charge attempt" do
          expect do
            expect do
              expect do
                post :create, params: single_purchase_params

                expect(response.parsed_body["success"]).to be(true)
                expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(false)
                expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)
              end.to change(Purchase.failed, :count).by(1)
            end.to change(Order, :count).by(1)
          end.to change(Charge, :count).by(1)

          order = Order.last
          charge = Charge.last
          purchase = Purchase.last
          expect(order.purchases.count).to eq(1)
          expect(order.purchases.last).to eq(purchase)
          expect(purchase.is_part_of_combined_charge?).to be true
          expect(order.charges.count).to eq(1)
          expect(order.charges.last).to eq(charge)
          expect(SendChargeReceiptJob).not_to have_enqueued_sidekiq_job(charge.id)
        end
      end

      context "when gifting a subscription" do
        let(:subscription_price) { 10_00 }
        let(:product) { create(:membership_product, price_cents: subscription_price) }

        let(:single_purchase_params) do
          {
            is_gift: "true",
            giftee_email: "giftee@gumroad.com",
            gift_note: "Happy birthday!",
            line_items: [{
              uid: "unique-id-0",
              permalink: product.unique_permalink,
              perceived_price_cents: subscription_price,
              quantity: 1
            }]
          }.merge(common_purchase_params)
        end

        it "creates a gift purchase" do
          expect do
            post :create, params: single_purchase_params

            expect(response.parsed_body["success"]).to be(true)
          end.to change(Purchase.successful, :count).by(1).and change(Order, :count).by(1)

          subscription = product.subscriptions.last
          expect(subscription).to have_attributes(
            link: product,
            cancelled_at: nil,
            credit_card: nil,
            email: "giftee@gumroad.com"
          )

          purchase = Purchase.successful.first
          expect(purchase).to have_attributes(
            is_gift_sender_purchase: true,
            is_original_subscription_purchase: true
          )

          order = Order.last
          expect(order.purchases.count).to eq(1)
          expect(order.purchases.last).to eq(purchase)

          gift = purchase.gift_given
          expect(gift).to have_attributes(
            successful?: true,
            gift_note: "Happy birthday!",
            giftee_email: "giftee@gumroad.com",
            gifter_email: "buyer@gumroad.com"
          )

          expect(gift.giftee_purchase).to have_attributes(
            purchase_state: "gift_receiver_purchase_successful",
            is_gift_sender_purchase: false,
            is_gift_receiver_purchase: true,
            is_original_subscription_purchase: false,
            price_cents: 0,
            total_transaction_cents: 0,
            displayed_price_cents: 0
          )
        end
      end

      context "when purchasing a call", :freeze_time do
        before { travel_to(DateTime.parse("May 1 2024 UTC")) }

        let!(:call_product) { create(:call_product, :available_for_a_year, price_cents: 10_00) }
        let!(:call_duration) { 30.minutes }
        let!(:call_option_30_minute) { create(:variant, name: "30 minute", duration_in_minutes: call_duration.in_minutes, variant_category: call_product.variant_categories.first) }
        let!(:call_start_time) { DateTime.parse("May 1 2024 10:28:30.123456 UTC") }
        let!(:normalized_call_start_time) { DateTime.parse("May 1 2024 10:28:00 UTC") }

        context "with all required values" do
          let(:call_purchase_params) do
            {
              line_items: [{
                uid: "call-product-uid",
                permalink: call_product.unique_permalink,
                perceived_price_cents: 10_00,
                quantity: 1,
                variants: [call_option_30_minute.external_id],
                call_start_time: call_start_time.iso8601
              }]
            }.merge(common_purchase_params)
          end

          it "creates a purchase with the correct start and end time" do
            expect do
              post :create, params: call_purchase_params
            end.to change(Purchase.successful, :count).by(1)

            purchase = Purchase.successful.last
            expect(purchase.call.start_time).to eq(normalized_call_start_time)
            expect(purchase.call.end_time).to eq(normalized_call_start_time + call_duration)
          end
        end

        context "missing variant selection" do
          let(:call_purchase_params) do
            {
              line_items: [{
                uid: "call-product-uid",
                permalink: call_product.unique_permalink,
                perceived_price_cents: 10_00,
                quantity: 1,
                call_start_time: call_start_time.iso8601
              }]
            }.merge(common_purchase_params)
          end

          it "returns an error for the line item" do
            post :create, params: call_purchase_params

            expect(response.parsed_body["line_items"]["call-product-uid"]["error_message"]).to eq("Please select a start time.")
          end
        end

        context "missing call start time" do
          let(:call_purchase_params) do
            {
              line_items: [{
                uid: "call-product-uid",
                permalink: call_product.unique_permalink,
                perceived_price_cents: 10_00,
                quantity: 1,
                variants: [call_option_30_minute.external_id]
              }]
            }.merge(common_purchase_params)
          end

          it "returns an error for the line item" do
            post :create, params: call_purchase_params

            expect(response.parsed_body["line_items"]["call-product-uid"]["error_message"]).to eq("Please select a start time.")
          end
        end

        context "invalid call start time" do
          let(:call_purchase_params) do
            {
              line_items: [{
                uid: "call-product-uid",
                permalink: call_product.unique_permalink,
                perceived_price_cents: 10_00,
                quantity: 1,
                variants: [call_option_30_minute.external_id],
                call_start_time: "invalid"
              }]
            }.merge(common_purchase_params)
          end

          it "returns an error for the line item" do
            post :create, params: call_purchase_params

            expect(response.parsed_body["line_items"]["call-product-uid"]["error_message"]).to eq("Please select a start time.")
          end
        end

        context "selected time is no longer available" do
          let(:call_purchase_params) do
            {
              line_items: [{
                uid: "call-product-uid",
                permalink: call_product.unique_permalink,
                perceived_price_cents: 10_00,
                quantity: 1,
                variants: [call_option_30_minute.external_id],
                call_start_time: 1.day.ago.iso8601
              }]
            }.merge(common_purchase_params)
          end

          it "returns an error for the line item" do
            post :create, params: call_purchase_params

            expect(response.parsed_body["line_items"]["call-product-uid"]["error_message"]).to eq("Call Selected time is no longer available")
          end
        end
      end

      describe "purchase attribution to UTM links", :sidekiq_inline do
        let(:browser_guid) { "123" }

        before do
          cookies[:_gumroad_guid] = browser_guid
          Feature.activate(:utm_links)
        end

        it "attributes the qualified purchase to the matching UTM link having a visit with the same browser guid" do
          expect(UtmLinkSaleAttributionJob).to receive(:perform_async).with(anything, browser_guid).and_call_original

          utm_link = create(:utm_link, seller: product_1.user)
          utm_link_visit = create(:utm_link_visit, utm_link:, browser_guid:)

          expect do
            post :create, params: single_purchase_params
          end.to change { utm_link.utm_link_driven_sales.count }.by(1)

          order = Order.last
          utm_link_driven_sale = utm_link.utm_link_driven_sales.sole
          expect(utm_link_driven_sale.purchase).to eq(order.purchases.successful.sole)
          expect(utm_link_driven_sale.utm_link_visit).to eq(utm_link_visit)
        end

        it "does not attribute purchase when there is no matching UTM link visit" do
          utm_link = create(:utm_link, seller: product_1.user)

          expect do
            post :create, params: single_purchase_params
          end.not_to change { utm_link.utm_link_driven_sales.count }
        end

        it "does not attribute purchase when browser guid does not match" do
          utm_link = create(:utm_link, seller: product_1.user)
          create(:utm_link_visit, utm_link:, browser_guid: "different_guid")

          expect do
            post :create, params: single_purchase_params
          end.not_to change { utm_link.utm_link_driven_sales.count }
        end

        it "does not attribute a failed purchase" do
          utm_link = create(:utm_link, seller: product_1.user)
          create(:utm_link_visit, utm_link:, browser_guid:)

          product_1.update!(max_purchase_count: 0)

          expect do
            post :create, params: single_purchase_params
          end.not_to change { utm_link.utm_link_driven_sales.count }
        end

        it "does not attribute a purchase if the :utm_links feature is not active" do
          utm_link = create(:utm_link, seller: product_1.user)
          create(:utm_link_visit, utm_link:, browser_guid:)

          Feature.deactivate(:utm_links)

          expect do
            post :create, params: single_purchase_params
          end.not_to change { utm_link.utm_link_driven_sales.count }
        end
      end
    end

    context "multiple purchases" do
      let(:payment_params) { StripePaymentMethodHelper.success.to_stripejs_params(prepare_future_payments: true) }
      let(:multiple_purchase_params) do
        {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: product_1.unique_permalink,
              perceived_price_cents: product_1.price_cents,
              quantity: 1
            },
            {
              uid: "unique-id-1",
              permalink: product_2.unique_permalink,
              perceived_price_cents: product_2.price_cents,
              quantity: 1
            }
          ]
        }.merge(common_purchase_params)
      end

      it "creates an order, the associated purchases and a combined charge" do
        expect do
          expect do
            expect do
              post :create, params: multiple_purchase_params
            end.to change(Purchase.successful, :count).by(2)
          end.to change(Charge, :count).by(1)
        end.to change(Order, :count).by(1)

        order = Order.last
        charge = Charge.last
        expect(order.purchases.count).to eq(2)
        expect(order.purchases.to_a).to eq(Purchase.successful.last(2))
        expect(order.charges.count).to eq(1)
        expect(order.charges.to_a).to eq([charge])
        expect(charge.purchases.count).to eq(2)
        expect(charge.amount_cents).to eq(Purchase.successful.last(2).sum(&:total_transaction_cents))
        expect(charge.gumroad_amount_cents).to eq(Purchase.successful.last(2).sum(&:fee_cents))
        expect(charge.stripe_payment_intent_id).to be_present
        expect(charge.processor_transaction_id).to be_present
        expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge.id)
      end

      it "creates an order, the associated purchases and a combined charge for each seller" do
        multi_seller_purchase_params = {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: product_1.unique_permalink,
              perceived_price_cents: product_1.price_cents,
              quantity: 1
            },
            {
              uid: "unique-id-1",
              permalink: product_2.unique_permalink,
              perceived_price_cents: product_2.price_cents,
              quantity: 1
            },
            {
              uid: "unique-id-2",
              permalink: product_3.unique_permalink,
              perceived_price_cents: product_3.price_cents,
              quantity: 1
            },
            {
              uid: "unique-id-3",
              permalink: product_4.unique_permalink,
              perceived_price_cents: product_4.price_cents,
              quantity: 1
            },
            {
              uid: "unique-id-4",
              permalink: product_5.unique_permalink,
              perceived_price_cents: product_5.price_cents,
              quantity: 1
            }
          ]
        }.merge(common_purchase_params)

        expect do
          expect do
            expect do
              post :create, params: multi_seller_purchase_params
            end.to change(Purchase.successful, :count).by(5)
          end.to change(Charge, :count).by(2)
        end.to change(Order, :count).by(1)

        expect(Order.last.purchases.count).to eq(5)
        expect(Order.last.purchases.to_a).to eq(Purchase.successful.last(5))
        expect(Order.last.charges.count).to eq(2)
        expect(Order.last.charges.to_a).to eq(Charge.last(2))

        charge_one = Charge.last(2).first
        expect(charge_one.purchases.count).to eq(2)
        expect(charge_one.amount_cents).to eq(charge_one.purchases.sum(&:total_transaction_cents))
        expect(charge_one.gumroad_amount_cents).to eq(charge_one.purchases.sum(&:fee_cents))
        expect(charge_one.stripe_payment_intent_id).to be_present
        expect(charge_one.processor_transaction_id).to be_present
        expect(charge_one.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge_one.processor_transaction_id])
        expect(charge_one.purchases.pluck(:credit_card_id).uniq).to eq([charge_one.credit_card_id])
        expect(charge_one.purchases.pluck(:merchant_account_id).uniq).to eq([charge_one.merchant_account_id])
        expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge_one.id)

        charge_two = Charge.last
        expect(charge_two.purchases.count).to eq(3)
        expect(charge_two.purchases.is_part_of_combined_charge.count).to eq 3
        expect(charge_two.amount_cents).to eq(charge_two.purchases.sum(&:total_transaction_cents))
        expect(charge_two.gumroad_amount_cents).to eq(charge_two.purchases.sum(&:fee_cents))
        expect(charge_two.stripe_payment_intent_id).to be_present
        expect(charge_two.processor_transaction_id).to be_present
        expect(charge_two.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge_two.processor_transaction_id])
        expect(charge_two.purchases.pluck(:credit_card_id).uniq).to eq([charge_two.credit_card_id])
        expect(charge_two.purchases.pluck(:merchant_account_id).uniq).to eq([charge_two.merchant_account_id])
        expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge_two.id)
      end

      describe "response format" do
        context "when all purchases succeed" do
          it "responds with success: true for every line item" do
            post :create, params: multiple_purchase_params

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(true)
            expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to be(true)
            expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)
          end
        end

        context "when all purchases fail" do
          let(:payment_params) { StripePaymentMethodHelper.decline.to_stripejs_params }

          it "responds with success: false for every line item" do
            post :create, params: multiple_purchase_params

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(false)
            expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to be(false)
            expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)
          end

          it "creates an order with purchases associated" do
            expect do
              expect do
                post :create, params: multiple_purchase_params
              end.to change(Purchase.failed, :count).by(2)
            end.to change(Order, :count).by(1)

            expect(Order.last.purchases.count).to eq(2)
            expect(Order.last.purchases.to_a).to eq(Purchase.failed.last(2))
          end
        end

        context "when some purchases fail and some succeed" do
          before do
            product_2.update_attribute(:max_purchase_count, 0)
          end

          it "responds with proper 'success' value for each line item" do
            post :create, params: multiple_purchase_params

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(true)
            expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to be(false)
            expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)
          end

          it "creates an order with purchases associated" do
            expect do
              expect do
                expect do
                  expect do
                    post :create, params: multiple_purchase_params
                  end.to change(Purchase, :count).by(2)
                end.to change(Purchase.successful, :count).by(1)
              end.to change(Purchase.failed, :count).by(1)
            end.to change(Order, :count).by(1)

            expect(Order.last.purchases.count).to eq(2)
            expect(Order.last.purchases.to_a).to eq([Purchase.successful.last, Purchase.failed.last])
          end
        end
      end

      context "when product is not found" do
        it "handles gracefully" do
          multiple_purchase_params[:line_items][1][:permalink] = "non-existent"

          expect do
            expect do
              expect do
                post :create, params: multiple_purchase_params
              end.to change(Purchase.successful, :count).by(1)
            end.to change(Purchase, :count).by(1)
          end.to change(Order, :count).by(1)

          order = Order.last
          charge = Charge.last
          expect(order.purchases.count).to eq(1)
          expect(order.purchases.to_a).to eq([Purchase.successful.last])
          expect(order.charges.count).to eq(1)
          expect(charge.purchases.to_a).to eq([Purchase.successful.last])
          expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to eq(true)
          expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to eq(false)
          expect(response.parsed_body["line_items"]["unique-id-1"]["error_message"]).to eq("Product not found")
          expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)
          expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge.id)
        end
      end

      it "saves the referrer" do
        multiple_purchase_params[:line_items][0][:referrer] = "https://facebook.com"
        multiple_purchase_params[:line_items][1][:referrer] = "https://google.com"

        post :create, params: multiple_purchase_params

        expect(Purchase.second_to_last.referrer).to eq "https://facebook.com"
        expect(Purchase.last.referrer).to eq "https://google.com"
      end

      it "creates purchase events" do
        multiple_purchase_params.merge!({
                                          referrer: "https://facebook.com",
                                          plugins: "adblocker",
                                          friend: "friendy"
                                        })
        multiple_purchase_params[:line_items][0][:was_product_recommended] = true
        multiple_purchase_params[:line_items][1][:was_product_recommended] = false

        expect do
          post :create, params: multiple_purchase_params
        end.to change { Event.count }.by(2)

        purchase_1 = Purchase.second_to_last
        event_1 = Event.second_to_last
        expect(event_1.purchase_id).to eq(purchase_1.id)
        expect(event_1.link_id).to eq(purchase_1.link_id)
        expect(event_1.event_name).to eq("purchase")
        expect(event_1.purchase_state).to eq("successful")
        expect(event_1.price_cents).to eq(purchase_1.price_cents)
        expect(event_1.was_product_recommended?).to eq(true)

        purchase_2 = Purchase.last
        event_2 = Event.last
        expect(event_2.purchase_id).to eq(purchase_2.id)
        expect(event_2.link_id).to eq(purchase_2.link_id)
        expect(event_2.event_name).to eq("purchase")
        expect(event_2.purchase_state).to eq("successful")
        expect(event_2.price_cents).to eq(purchase_2.price_cents)
        expect(event_2.was_product_recommended?).to eq(false)
      end

      it "saves recommended information" do
        original_product = create(:product)
        allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)

        multiple_purchase_params[:line_items] += [
          {
            uid: "unique-id-2",
            permalink: product_3.unique_permalink,
            perceived_price_cents: price_3,
            quantity: 1,
            was_product_recommended: true,
            recommended_by: "search"
          }, {
            uid: "unique-id-3",
            permalink: product_4.unique_permalink,
            perceived_price_cents: price_4,
            quantity: 1,
            was_product_recommended: true,
            recommended_by: "receipt"
          }, {
            uid: "unique-id-4",
            permalink: product_5.unique_permalink,
            perceived_price_cents: price_5,
            quantity: 1,
            was_product_recommended: true,
            recommended_by: original_product.unique_permalink
          }
        ]

        multiple_purchase_params[:line_items][0].merge!(was_product_recommended: true, recommended_by: "discover")
        multiple_purchase_params[:line_items][1].merge!(was_product_recommended: false)

        post :create, params: multiple_purchase_params

        purchase_1 = Purchase.first
        expect(purchase_1.was_product_recommended).to eq true
        expect(purchase_1.recommended_purchase_info).to be_present
        expect(purchase_1.recommended_purchase_info.recommendation_type).to eq RecommendationType::GUMROAD_DISCOVER_RECOMMENDATION
        expect(purchase_1.recommended_purchase_info.recommended_link).to eq purchase_1.link
        expect(purchase_1.recommended_purchase_info.recommended_by_link).to be_nil
        expect(purchase_1.recommended_purchase_info.discover_fee_per_thousand).to eq(100)
        expect(purchase_1.discover_fee_per_thousand).to eq(100)

        purchase_2 = Purchase.second
        expect(purchase_2.was_product_recommended).to eq false
        expect(purchase_2.recommended_purchase_info).to be_nil

        purchase_3 = Purchase.third
        expect(purchase_3.was_product_recommended).to eq true
        expect(purchase_3.recommended_purchase_info).to be_present
        expect(purchase_3.recommended_purchase_info.recommendation_type).to eq RecommendationType::GUMROAD_SEARCH_RECOMMENDATION
        expect(purchase_3.recommended_purchase_info.recommended_link).to eq purchase_3.link
        expect(purchase_3.recommended_purchase_info.recommended_by_link).to be_nil
        expect(purchase_3.recommended_purchase_info.discover_fee_per_thousand).to eq(100)
        expect(purchase_3.discover_fee_per_thousand).to eq(100)

        purchase_4 = Purchase.fourth
        expect(purchase_4.was_product_recommended).to eq true
        expect(purchase_4.recommended_purchase_info).to be_present
        expect(purchase_4.recommended_purchase_info.recommendation_type).to eq RecommendationType::GUMROAD_RECEIPT_RECOMMENDATION
        expect(purchase_4.recommended_purchase_info.recommended_link).to eq purchase_4.link
        expect(purchase_4.recommended_purchase_info.recommended_by_link).to be_nil
        expect(purchase_4.recommended_purchase_info.discover_fee_per_thousand).to eq(100)
        expect(purchase_4.discover_fee_per_thousand).to eq(100)

        purchase_5 = Purchase.fifth
        expect(purchase_5.was_product_recommended).to eq true
        expect(purchase_5.recommended_purchase_info).to be_present
        expect(purchase_5.recommended_purchase_info.recommendation_type).to eq RecommendationType::PRODUCT_RECOMMENDATION
        expect(purchase_5.recommended_purchase_info.recommended_link).to eq purchase_5.link
        expect(purchase_5.recommended_purchase_info.recommended_by_link).to eq original_product
        expect(purchase_5.recommended_purchase_info.discover_fee_per_thousand).to eq(300)
      end

      describe "chargeable construction" do
        let(:payment_params) { { stripe_payment_method_id: "stripe-payment-method-id" } }

        before do
          cookies[:_gumroad_guid] = "random-guid"
        end

        it "passes in the _gumroad_guid from cookies along with the purchase params" do
          expect(CardParamsHelper).to receive(:build_chargeable).with(
            hash_including(stripe_payment_method_id: "stripe-payment-method-id"),
            cookies[:_gumroad_guid]
          )

          post :create, params: multiple_purchase_params
        end
      end

      describe "paypal native" do
        let(:multiple_purchase_params_with_pp_native) do
          {
            line_items: [{
              uid: "unique-id-0",
              permalink: product_1.unique_permalink,
              perceived_price_cents: price_1,
              quantity: 1
            }]
          }.merge(common_purchase_params_with_native_pp)
        end

        before do
          allow_any_instance_of(User).to receive(:native_paypal_payment_enabled?).and_return(true)
          create(:merchant_account_paypal, user: product_1.user, charge_processor_merchant_id: "B66YJBBNCRW6L")
        end

        it "preserves paypal_order_id for correct charging" do
          expect do
            post :create, params: multiple_purchase_params_with_pp_native
          end.to change { Purchase.count }.by 1

          p = Purchase.successful.last
          expect(p.paypal_order_id).to be_present
        end
      end

      describe "single item purchases that require SCA" do
        let(:price) { 10_00 }
        let(:multiple_purchase_params_with_sca) do
          common_purchase_params_with_sca.merge(
            line_items: [{
              uid: "unique-uid-0",
              permalink: product.unique_permalink,
              perceived_price_cents: price,
              quantity: 1,
            }]
          )
        end

        describe "preorder" do
          let(:product) { create(:product, price_cents: price, is_in_preorder_state: true) }
          let!(:preorder_product) { create(:preorder_link, link: product) }

          before do
            allow_any_instance_of(StripeSetupIntent).to receive(:requires_action?).and_return(true)
          end

          it "creates an in_progress purchase and preorder and renders a proper response" do
            expect do
              expect do
                expect do
                  multiple_purchase_params_with_sca[:line_items][0].merge!(is_preorder: "true")
                  post :create, params: multiple_purchase_params_with_sca

                  expect(FailAbandonedPurchaseWorker).to have_enqueued_sidekiq_job(Purchase.last.id)

                  expect(response.parsed_body["success"]).to be(true)
                  expect(response.parsed_body["line_items"]["unique-uid-0"]["success"]).to be(true)
                  expect(response.parsed_body["line_items"]["unique-uid-0"]["requires_card_setup"]).to be(true)
                  expect(response.parsed_body["line_items"]["unique-uid-0"]["client_secret"]).to be_present
                  expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)
                end.to change(Purchase.in_progress, :count).by(1)
              end.to change(Preorder.in_progress, :count).by(1)
            end.to change(Order, :count).by(1)

            expect(Order.last.purchases.count).to eq(1)
            expect(Order.last.purchases.to_a).to eq([Purchase.in_progress.last])
            expect(Order.last.charges.count).to eq(1)
          end
        end

        describe "classic product" do
          let(:product) { create(:product, price_cents: price) }

          before do
            allow_any_instance_of(StripeChargeIntent).to receive(:requires_action?).and_return(true)
          end

          it "creates an in_progress purchase and renders a proper response" do
            expect do
              expect do
                post :create, params: multiple_purchase_params_with_sca

                expect(FailAbandonedPurchaseWorker).to have_enqueued_sidekiq_job(Purchase.last.id)

                expect(response.parsed_body["success"]).to be(true)
                expect(response.parsed_body["line_items"]["unique-uid-0"]["success"]).to be(true)
                expect(response.parsed_body["line_items"]["unique-uid-0"]["requires_card_action"]).to be(true)
                expect(response.parsed_body["line_items"]["unique-uid-0"]["client_secret"]).to be_present
                expect(response.parsed_body["line_items"]["unique-uid-0"]["order"]["id"]).to eq(Order.last.external_id)
                expect(response.parsed_body["line_items"]["unique-uid-0"]["order"]["stripe_connect_account_id"]).to be_nil
                expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)
              end.to change(Purchase.in_progress, :count).by(1)
            end.to change(Order, :count).by(1)

            expect(Order.last.purchases.count).to eq(1)
            expect(Order.last.purchases.to_a).to eq([Purchase.in_progress.last])
          end

          it "creates an in_progress purchase and renders a proper response for stripe connect account" do
            allow_any_instance_of(User).to receive(:check_merchant_account_is_linked).and_return(true)
            create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1MeFbmKQKir5qdfM", user: product.user)

            expect do
              expect do
                post :create, params: multiple_purchase_params_with_sca

                expect(FailAbandonedPurchaseWorker).to have_enqueued_sidekiq_job(Purchase.last.id)

                expect(response.parsed_body["success"]).to be(true)
                expect(response.parsed_body["line_items"]["unique-uid-0"]["success"]).to be(true)
                expect(response.parsed_body["line_items"]["unique-uid-0"]["requires_card_action"]).to be(true)
                expect(response.parsed_body["line_items"]["unique-uid-0"]["client_secret"]).to be_present
                expect(response.parsed_body["line_items"]["unique-uid-0"]["order"]["id"]).to eq(Order.last.external_id)
                expect(response.parsed_body["line_items"]["unique-uid-0"]["order"]["stripe_connect_account_id"]).to eq("acct_1MeFbmKQKir5qdfM")
                expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)
              end.to change(Purchase.in_progress, :count).by(1)
            end.to change(Order, :count).by(1)

            expect(Order.last.purchases.count).to eq(1)
            expect(Order.last.purchases.to_a).to eq([Purchase.in_progress.last])
          end
        end

        describe "membership" do
          let(:product) { create(:subscription_product, price_cents: price) }

          before do
            allow_any_instance_of(StripeChargeIntent).to receive(:requires_action?).and_return(true)
          end

          it "creates an in_progress purchase and renders a proper response" do
            expect do
              expect do
                expect do
                  post :create, params: multiple_purchase_params_with_sca

                  expect(FailAbandonedPurchaseWorker).to have_enqueued_sidekiq_job(Purchase.last.id)

                  expect(response.parsed_body["success"]).to be(true)
                  expect(response.parsed_body["line_items"]["unique-uid-0"]["success"]).to be(true)
                  expect(response.parsed_body["line_items"]["unique-uid-0"]["requires_card_action"]).to be(true)
                  expect(response.parsed_body["line_items"]["unique-uid-0"]["client_secret"]).to be_present
                  expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)
                end.to change(Purchase.in_progress, :count).by(1)
              end.not_to change(Subscription, :count)
            end.to change(Order, :count).by(1)

            expect(Order.last.purchases.count).to eq(1)
            expect(Order.last.purchases.to_a).to eq([Purchase.in_progress.last])
          end
        end
      end

      it "filters sensitive parameters" do
        sensitive_params = %i[password cc_number number expiry_date cc_expiry cvc account_number account_number_repeated passphrase chargeable]
        received_params = nil
        multiple_purchase_params.merge!(sensitive_params.reduce({}) do |h, key|
          h.merge(key => (0...50).map { ("a".."z").to_a[rand(26)] })
        end)
        expect(Rails.logger).to receive(:info).at_least(3).times do |e|
          received_params = eval(e.gsub(/Parameters:/, "").strip).symbolize_keys if e.include?("Parameters")
        end

        run_with_log_level(Logger::INFO) do
          post(:create, params: multiple_purchase_params)
        end

        sensitive_params.each { |key| expect(received_params[key]).to eq("[FILTERED]") }
      end

      describe "allow user to test buying their own links" do
        before do
          @user = create(:user)
          sign_in(@user)
          @product = create(:product, user: @user)
          @redirect = create(:url_redirect, link: @product)
          @variant = create(:variant, name: "blue", variant_category: create(:variant_category, link: @product))
          @variant2 = create(:variant, name: "small", variant_category: create(:variant_category, link: @product))

          multiple_purchase_params[:line_items] = [{
            uid: "unique-uid-0",
            permalink: @product.unique_permalink,
            perceived_price_cents: @product.price_cents,
            variants: [@variant.external_id, @variant2.external_id],
            quantity: 1
          }]
          multiple_purchase_params.merge!(
            email: "buyer@gumroad.com",
            full_name: "gumroad buyer",
            )
        end

        it "creates a test purchase" do
          expect do
            expect do
              post :create, params: multiple_purchase_params
              expect(response.parsed_body["line_items"]["unique-uid-0"]["success"]).to be true
              expect(response.parsed_body["can_buyer_sign_up"]).to eq(false)
            end.to change { Purchase.count }.by 1
          end.to change { Order.count }.by(1)
        end

        it "sends the notification webhook if user requested" do
          @user.update_attribute(:notification_endpoint, "http://example.com")
          post :create, params: multiple_purchase_params

          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(Purchase.last.id, nil)
        end

        it "sends the correct receipt" do
          allow(UrlRedirect).to receive(:create!).and_return(@redirect)
          expect(CustomerMailer).not_to receive(:receipt)

          expect { post :create, params: multiple_purchase_params }.to change { Charge.count }.by(1)

          expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(Charge.last.id)
        end
      end

      it "doesn't allow it to go through if the guid is blank" do
        cookies[:_gumroad_guid] = ""
        expect do
          post :create, params: multiple_purchase_params
          expect(response.parsed_body["success"]).to be(false)
        end.not_to change(Purchase, :count)
      end

      describe "reCAPTCHA skipping behavior" do
        it "does not attempt to verify reCAPTCHA if all purchases are free and don't require captcha" do
          allow_any_instance_of(Link).to receive(:require_captcha?).and_return(false)

          product_1.update!(price_cents: 0)
          product_2.update!(price_cents: 0)

          multiple_purchase_params[:line_items][0][:perceived_price_cents] = "0"
          multiple_purchase_params[:line_items][1][:perceived_price_cents] = "0"

          expect_any_instance_of(OrdersController).to_not receive(:valid_recaptcha_response_and_hostname?)

          expect do
            post :create, params: multiple_purchase_params
          end.to change(Purchase.successful, :count).by(2)
        end

        it "verifies reCAPTCHA if any of the purchases require it" do
          allow_any_instance_of(Link).to receive(:require_captcha?).and_return(true)

          product_1.update!(price_cents: 0)
          product_2.update!(price_cents: 0)

          multiple_purchase_params[:line_items][0][:perceived_price_cents] = "0"
          multiple_purchase_params[:line_items][1][:perceived_price_cents] = "0"

          expect_any_instance_of(OrdersController).to receive(:valid_recaptcha_response_and_hostname?).and_return(true)

          expect do
            post :create, params: multiple_purchase_params
          end.to change(Purchase.successful, :count).by(2)
        end

        context "when payment is made using a wallet" do
          let(:payment_method) do
            payment_method = StripePaymentMethodHelper.success.to_stripejs_wallet_payment_method
            allow(Stripe::PaymentMethod).to receive(:retrieve).and_return(payment_method)
            payment_method
          end
          let(:payment_params) { { wallet_type: "apple_pay", stripe_payment_method_id: payment_method.id } }

          it "does not attempt to verify reCAPTCHA if payment is made using a wallet" do
            expect_any_instance_of(OrdersController).to_not receive(:valid_recaptcha_response_and_hostname?)

            post :create, params: multiple_purchase_params
          end
        end
      end

      it "doesn't allow purchasing if reCAPTCHA verification fails" do
        allow_any_instance_of(OrdersController).to receive(:valid_recaptcha_response_and_hostname?).and_return(false)

        expect do
          expect do
            post :create, params: multiple_purchase_params
          end.not_to change(Purchase, :count)
        end.not_to change(Purchase, :count)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq false
        expect(response.parsed_body["error_message"]).to eq "Sorry, we could not verify the CAPTCHA. Please try again."
        expect(response.parsed_body["can_buyer_sign_up"]).to be_nil
      end

      it "allows purchasing if reCAPTCHA verification succeeds" do
        allow_any_instance_of(OrdersController).to receive(:valid_recaptcha_response_and_hostname?).and_return(true)

        expect do
          post :create, params: multiple_purchase_params
        end.to change(Purchase, :count).by(2)
      end

      it "saves the user's locale in json_data" do
        expect do
          post :create, params: multiple_purchase_params.merge(locale: "de")
        end.to change(Purchase.successful, :count).by(2)

        expect(Purchase.second_to_last.locale).to eq "de"
        expect(Purchase.last.locale).to eq "de"
      end

      it "does not expire the product action cache" do
        Rails.cache.write("views/#{product_1.unique_permalink}_en.html", "<html>hello</html>")
        post :create, params: multiple_purchase_params
        expect(Rails.cache.read("views/#{product_1.unique_permalink}_en.html")).to_not be(nil)
      end

      describe "purchase with variants" do
        let(:category) { create(:variant_category, title: "sizes", link: product_2) }
        let(:variant) { create(:variant, name: "small", max_purchase_count: 2, variant_category: category) }

        context "when variant is sold out" do
          before do
            2.times { |i| create(:purchase, link: product_2, email: "test+#{i}@gumroad.com", variant_attributes: [variant]) }
          end

          it "blocks the purchase if the variant is sold out" do
            multiple_purchase_params[:line_items][1][:variants] = [variant.external_id]

            post :create, params: multiple_purchase_params

            expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(true)
            expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to be(false)
            expect(response.parsed_body["line_items"]["unique-id-1"]["error_message"]).to eq "Sold out, please go back and pick another option."
          end
        end

        context "when variant is available" do
          it "allows the purchase" do
            multiple_purchase_params[:line_items][1][:variants] = [variant.external_id]

            expect do
              post :create, params: multiple_purchase_params
            end.to change(Purchase.successful, :count).by(2)
          end
        end

        describe "multi-quanity" do
          it "allows a multi-quantity purchase" do
            multiple_purchase_params[:line_items][1].merge!(
              variants: [variant.external_id],
              perceived_price_cents: product_2.price_cents * 2,
              quantity: 2
            )

            expect do
              post :create, params: multiple_purchase_params
            end.to change(Purchase.successful, :count).by(2)
          end

          it "does not allow a multi-quantity purchase if the quantity exceeds the variant availability" do
            multiple_purchase_params[:line_items][1].merge!(
              variants: [variant.external_id],
              perceived_price_cents: product_2.price_cents * 4,
              quantity: 4
            )

            expect do
              post :create, params: multiple_purchase_params
            end.to change(Purchase, :count).by(2)

            expect(Purchase.second_to_last.purchase_state).to eq("successful")

            expect(Purchase.last.purchase_state).to eq("failed")
            expect(Purchase.last.error_code).to eq "exceeding_variant_quantity"
          end
        end

        describe "physical product with skus" do
          let(:product_2) { create(:physical_product, price_cents: price_2) }

          it "adds the default sku to the purchase and allow the purchase" do
            post :create, params: multiple_purchase_params

            expect(Purchase.last.variant_attributes.count).to eq(1)
            expect(Purchase.last.variant_attributes).to eq(product_2.skus.is_default_sku)
          end

          it "does not add the default sku to the purchase if one exists" do
            Product::SkusUpdaterService.new(product: product_2).perform
            sku = Sku.last
            multiple_purchase_params[:line_items][1][:variants] = { "0" => sku.external_id }

            post :create, params: multiple_purchase_params

            expect(Purchase.last.variant_attributes.count).to eq(1)
            expect(Purchase.last.variant_attributes.first).to eq(sku)
          end
        end

        describe "variants with price_difference_cents" do
          let(:variant) { create(:variant, name: "small", price_difference_cents: 200, max_purchase_count: 2, variant_category: category) }

          describe "fixed price" do
            context "when perceived_price_cents is incorrect" do
              it "rejects the purchase" do
                multiple_purchase_params[:line_items][1][:variants] = [variant.external_id]
                post :create, params: multiple_purchase_params

                expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(true)
                expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to be(false)
                expect(response.parsed_body["line_items"]["unique-id-1"]["error_code"]).to eq("perceived_price_cents_not_matching")
              end
            end

            describe "perceived_price_cents is correct" do
              it "allows the purchase" do
                multiple_purchase_params[:line_items][1].merge!(
                  variants: [variant.external_id],
                  perceived_price_cents: price_2 + 200
                )
                expect do
                  post :create, params: multiple_purchase_params
                end.to change(Purchase.successful, :count).by(2)
              end
            end
          end

          describe "variable pricing" do
            before do
              product_2.update(price_range: "3+")
            end

            it "rejects purchase if range is not great enough" do
              multiple_purchase_params[:line_items][1].merge!(
                variants: [variant.external_id],
                price_range: 3,
                perceived_price_cents: 3
              )

              post :create, params: multiple_purchase_params
              expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(true)
              expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to be(false)
              expect(response.parsed_body["line_items"]["unique-id-1"]["error_code"]).to eq("contribution_too_low")
            end

            it "allows purchase if price_range sufficient" do
              multiple_purchase_params[:line_items][1].merge!(
                variants: [variant.external_id],
                price_range: 6,
                perceived_price_cents: 5_00
              )

              expect do
                post :create, params: multiple_purchase_params
              end.to change(Purchase.successful, :count).by(2)
            end

            describe "multiple quantity" do
              it "rejects purchase if range is not great enough" do
                multiple_purchase_params[:line_items][1].merge!(
                  variants: [variant.external_id],
                  quantity: 2,
                  price_range: 3,
                  perceived_price_cents: 3
                )

                post :create, params: multiple_purchase_params
                expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(true)
                expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to be(false)
                expect(response.parsed_body["line_items"]["unique-id-1"]["error_code"]).to eq("contribution_too_low")
              end

              it "allows purchase if price_range sufficient" do
                multiple_purchase_params[:line_items][1].merge!(
                  variants: [variant.external_id],
                  quantity: 2,
                  price_range: 12,
                  perceived_price_cents: 12_00
                )

                expect do
                  post :create, params: multiple_purchase_params
                  expect(response.parsed_body["line_items"]["unique-id-1"]["non_formatted_price"]).to eq(1200)
                end.to change(Purchase.successful, :count).by(2)
              end
            end
          end
        end
      end

      it "does not add the purchases made into the session anymore" do
        post :create, params: multiple_purchase_params
        expect(session["purchased_links"]).to be(nil)
      end

      describe "custom fields" do
        let(:country_field) { create(:custom_field, name: "country", required: true) }
        let(:zip_field) { create(:custom_field, name: "zip", required: false) }
        let(:checkbox_field) { create(:custom_field, name: "Brazilian", type: CustomField::TYPE_CHECKBOX, required: false) }

        before { product_2.custom_fields << [country_field, zip_field, checkbox_field] }

        it "fails the purchase if required custom fields are not filled in" do
          expect { post :create, params: multiple_purchase_params }.to change(Purchase, :count).by(1)

          expect(response).to be_successful
          expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to eq true
          expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to eq false
          expect(response.parsed_body["line_items"]["unique-id-1"]["error_message"]).to eq "Purchase custom fields is invalid"
        end

        it "adds custom fields to the purchase object" do
          multiple_purchase_params[:line_items][1][:custom_fields] = [{ id: country_field.external_id, value: "Brazil" }, { id: zip_field.external_id, value: "12356" }]
          post :create, params: multiple_purchase_params
          expect(Purchase.last.custom_fields).to eq(
            [
              { name: "country", value: "Brazil", type: CustomField::TYPE_TEXT },
              { name: "zip", value: "12356", type: CustomField::TYPE_TEXT },
              { name: "Brazilian", value: false, type: CustomField::TYPE_CHECKBOX }
            ]
          )
        end

        it "does not set custom fields that are not set on the product" do
          other_field = create(:custom_field)
          multiple_purchase_params[:line_items][1][:custom_fields] = [{ id: country_field.external_id, value: "Brazil" }, { id: zip_field.external_id, value: "12356" }, { id: other_field.external_id, value: "not-permitted" }]
          post :create, params: multiple_purchase_params
          expect(Purchase.last.custom_fields).to eq(
            [
              { name: "country", value: "Brazil", type: CustomField::TYPE_TEXT },
              { name: "zip", value: "12356", type: CustomField::TYPE_TEXT },
              { name: "Brazilian", value: false, type: CustomField::TYPE_CHECKBOX }
            ]
          )
        end

        context "for terms and checkbox fields" do
          let(:terms_field) { create(:custom_field, name: "https://example.com", type: "terms") }

          before { product_2.custom_fields << terms_field }

          it "transforms field values to boolean for terms" do
            multiple_purchase_params[:line_items][1][:custom_fields] = [{ id: country_field.external_id, value: "Brazil" }, { id: terms_field.external_id, value: true }]
            post :create, params: multiple_purchase_params
            expect(Purchase.last.custom_fields).to eq(
              [
                { name: "country", value: "Brazil", type: CustomField::TYPE_TEXT },
                { name: "Brazilian", value: false, type: CustomField::TYPE_CHECKBOX },
                { name: "https://example.com", value: true, type: CustomField::TYPE_TERMS }
              ]
            )
          end

          it "transforms field values to boolean for checkbox" do
            multiple_purchase_params[:line_items][1][:custom_fields] = [{ id: country_field.external_id, value: "Brazil" }, { id: terms_field.external_id, value: true }, { id: checkbox_field.external_id, value: true }]
            post :create, params: multiple_purchase_params
            expect(Purchase.last.custom_fields).to eq(
              [
                { name: "country", value: "Brazil", type: CustomField::TYPE_TEXT },
                { name: "Brazilian", value: true, type: CustomField::TYPE_CHECKBOX },
                { name: "https://example.com", value: true, type: CustomField::TYPE_TERMS }
              ]
            )
          end
        end

        describe "bundles" do
          let(:bundle_text_field) { create(:custom_field, name: "Text field") }
          let(:bundle_checkbox_field) { create(:custom_field, name: "Checkbox field", type: CustomField::TYPE_CHECKBOX) }
          let(:bundle_terms_field) { create(:custom_field, name: "https://example.com", type: CustomField::TYPE_TERMS) }

          let(:product_in_bundle) do
            create(
              :product,
              user: seller_1,
              custom_fields: [bundle_text_field, bundle_checkbox_field, bundle_terms_field]
            )
          end

          let(:product_2) do
            create(
             :product,
             :bundle,
             user: seller_1,
             bundle_products: [
               build(:bundle_product, product: product_in_bundle)
             ]
           )
          end
          let(:bundle_product) { product_2.bundle_products.first }

          it "sets the bundle custom fields" do
            multiple_purchase_params[:line_items][1][:custom_fields] = [
              { id: country_field.external_id, value: "UK" }
            ]
            multiple_purchase_params[:line_items][1][:bundle_products] = [
              {
                product_id: bundle_product.product.external_id,
                quantity: 1,
                custom_fields: [
                  { id: bundle_text_field.external_id, value: "Hi" },
                  { id: bundle_checkbox_field.external_id, value: true },
                  { id: bundle_terms_field.external_id, value: true }
                ]
              }
            ]
            post :create, params: multiple_purchase_params

            purchase = Purchase.is_bundle_purchase.last
            expect(purchase.purchase_custom_fields.size).to eq(2)
            expect(purchase.purchase_custom_fields.first).to have_attributes(name: "country", value: "UK", bundle_product: nil)
            expect(purchase.purchase_custom_fields.second).to have_attributes(name: "Brazilian", value: false, bundle_product: nil)
            product_purchase = purchase.product_purchases.sole
            expect(product_purchase.purchase_custom_fields.size).to eq(3)
            expect(product_purchase.purchase_custom_fields.first).to have_attributes(name: "Text field", value: "Hi", bundle_product: nil)
            expect(product_purchase.purchase_custom_fields.second).to have_attributes(name: "Checkbox field", value: true, bundle_product: nil)
            expect(product_purchase.purchase_custom_fields.third).to have_attributes(name: "https://example.com", value: true, bundle_product: nil)
          end
        end
      end

      describe "affiliates" do
        let(:price_1) { 10_00 }
        let(:affiliate_user) { create(:affiliate_user) }
        let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller: product_1.user, affiliate_basis_points: 1000, products: [product_1]) }

        before do
          cookies["#{Affiliate::AFFILIATE_COOKIE_NAME_PREFIX}#{direct_affiliate.external_id}"] = Time.current.to_i
        end

        it "allows an affiliate purchase to go through and associates the purchase to the affiliate through AffiliateCredit" do
          expect do
            post :create, params: multiple_purchase_params
          end.to change(Purchase.successful, :count).by(2)

          purchase_1 = Purchase.second_to_last
          expect(purchase_1.affiliate_credit_cents).to eq(79)
          expect(purchase_1.affiliate).to eq(direct_affiliate)
          expect(purchase_1.affiliate_credit.affiliate).to eq(direct_affiliate)
          expect(product_1.user.unpaid_balance_cents).to eq(1503) # 712 (price - fee - affiliate) + 791 (price - fee)
          expect(affiliate_user.unpaid_balance_cents).to eq(79)

          purchase_2 = Purchase.last
          expect(purchase_2.affiliate_credit_cents).to eq(0)
          expect(purchase_2.affiliate).to be_nil
          expect(purchase_2.affiliate_credit).to be_nil
          expect(product_2.user.unpaid_balance_cents).to eq(1503) # product 1 and 2 sellers are same
        end

        context "when multiple affiliates have referred the buyer" do
          let(:affiliate_user_1) { create(:affiliate_user) }
          let(:affiliate_user_2) { create(:affiliate_user) }
          let(:direct_affiliate_1) { create(:direct_affiliate, affiliate_user: affiliate_user_1, seller: product_1.user, affiliate_basis_points: 1500, products: [product_1]) }
          let(:direct_affiliate_2) { create(:direct_affiliate, affiliate_user: affiliate_user_2, seller: product_1.user, affiliate_basis_points: 1500, products: [product_1]) }

          before do
            cookies["#{Affiliate::AFFILIATE_COOKIE_NAME_PREFIX}#{direct_affiliate_2.external_id}"] = Time.current.to_i
            cookies["#{Affiliate::AFFILIATE_COOKIE_NAME_PREFIX}#{direct_affiliate_1.external_id}"] = Time.current.to_i + 10

            affiliate_user_1.flag_for_fraud!(author_id: User.last.id)
            affiliate_user_1.suspend_for_fraud!(author_id: User.last.id)
            affiliate_user_2.flag_for_tos_violation!(author_id: User.last.id, product_id: Link.last.id)
            affiliate_user_2.suspend_for_tos_violation!(author_id: User.last.id)
          end

          it "gives credit to the last non-suspended affiliate that referred the buyer" do
            post :create, params: multiple_purchase_params

            affiliate_purchase = Purchase.second_to_last
            expect(affiliate_purchase.affiliate).to eq(direct_affiliate) # affiliate_1 & affiliate_2 are suspended
            expect(affiliate_purchase.affiliate_credit_cents).to eq(79)
            expect(affiliate_purchase.affiliate_credit.affiliate).to eq(direct_affiliate)
            expect(product_1.user.unpaid_balance_cents).to eq(1503)
            expect(direct_affiliate.affiliate_user.unpaid_balance_cents).to eq(79)
          end

          it "credits a direct affiliate if a cookie is set for a different product by that seller" do
            direct_affiliate.products = [create(:product, user: product_1.user)]
            create(:product_affiliate, affiliate: direct_affiliate, product: product_1, affiliate_basis_points: 20_00)

            post :create, params: multiple_purchase_params

            affiliate_purchase = Purchase.second_to_last
            expect(affiliate_purchase.affiliate).to eq(direct_affiliate) # affiliate_1 & affiliate_2 are suspended
            expect(affiliate_purchase.affiliate_credit_cents).to eq(158)
            expect(affiliate_purchase.affiliate_credit.affiliate).to eq(direct_affiliate)
            expect(product_1.user.unpaid_balance_cents).to eq(1424)
            expect(direct_affiliate.affiliate_user.unpaid_balance_cents).to eq(158)
          end

          it "does not credit the affiliate if a cookie is set for a product by a different seller" do
            other_product = create(:product)
            direct_affiliate.update!(seller_id: other_product.user_id)
            direct_affiliate.products = [other_product]
            create(:direct_affiliate, affiliate_user:, seller: product_1.user, affiliate_basis_points: 2000, products: [product_1])

            post :create, params: multiple_purchase_params

            affiliate_purchase = Purchase.second_to_last
            expect(affiliate_purchase.affiliate).to be_nil
          end

          it "credits the direct affiliate over the global affiliate if both exist" do
            product = create(:product, :recommendable)
            global_affiliate = affiliate_user.global_affiliate
            product_affiliate = create(:direct_affiliate, affiliate_user:, seller: product.user, affiliate_basis_points: 2000, products: [product])

            cookies["#{Affiliate::AFFILIATE_COOKIE_NAME_PREFIX}#{global_affiliate.external_id}"] = Time.current.to_i

            params = multiple_purchase_params
            params[:line_items][0][:permalink] = product.unique_permalink
            params[:line_items][0][:perceived_price_cents] = product.price_cents

            post(:create, params:)

            affiliate_purchase = Purchase.second_to_last
            expect(affiliate_purchase.affiliate).to eq(product_affiliate)
          end

          it "does not credit a global affiliate that does not have a cookie set, even if another cookie is set for that seller's products" do
            product = create(:product, :recommendable)
            product_affiliate = create(:direct_affiliate, affiliate_user:, seller: product.user, affiliate_basis_points: 2000, products: [create(:product, :recommendable, user: product.user)])

            cookies["#{Affiliate::AFFILIATE_COOKIE_NAME_PREFIX}#{product_affiliate.external_id}"] = Time.current.to_i

            params = multiple_purchase_params
            params[:line_items][0][:permalink] = product.unique_permalink
            params[:line_items][0][:perceived_price_cents] = product.price_cents

            post(:create, params:)

            affiliate_purchase = Purchase.second_to_last
            expect(affiliate_purchase.affiliate).to be_nil
          end

          it "does not credit a global affiliate that makes the purchase themself (to fraudently obtain a discount)" do
            common_purchase_params[:email] = affiliate_user.email
            product = create(:product, :recommendable)
            global_affiliate = affiliate_user.global_affiliate

            params = multiple_purchase_params
            params[:line_items][0][:permalink] = product.unique_permalink
            params[:line_items][0][:affiliate_id] = global_affiliate.external_id_numeric
            params[:line_items][0][:perceived_price_cents] = product.price_cents

            post(:create, params:)

            affiliate_purchase = Purchase.second_to_last
            expect(affiliate_purchase.affiliate).to be_nil
          end

          it "does not set the (externally supplied) `affiliate_id` for an ineligible affiliate purchase" do
            product = create(:product)
            affiliate = affiliate_user.global_affiliate

            params = multiple_purchase_params
            params[:line_items][0][:permalink] = product.unique_permalink
            params[:line_items][0][:affiliate_id] = affiliate.external_id_numeric
            params[:line_items][0][:perceived_price_cents] = product.price_cents

            post(:create, params:)

            purchase = Purchase.second_to_last
            expect(purchase.affiliate_id).to be_nil
          end
        end

        describe "recommended product" do
          before do
            multiple_purchase_params[:line_items][0].merge!(was_product_recommended: true, recommended_by: "discover")
            multiple_purchase_params[:line_items][1].merge!(was_product_recommended: true, recommended_by: "discover")
            allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
          end

          it "allows the purchase to go through as a recommended product purchase, not associated with an affiliate" do
            post :create, params: multiple_purchase_params

            purchase_1 = Purchase.second_to_last
            expect(purchase_1.was_product_recommended).to eq(true)
            expect(purchase_1.affiliate_credit_cents).to eq(0)
            expect(purchase_1.affiliate).to be_nil
            expect(purchase_1.affiliate_credit).to be_nil
            expect(purchase_1.fee_cents).to eq(300)
            expect(product_1.user.unpaid_balance_cents).to eq(1400)

            purchase_2 = Purchase.last
            expect(purchase_2.was_product_recommended).to eq(true)
            expect(purchase_2.affiliate_credit_cents).to eq(0)
            expect(purchase_2.affiliate).to be_nil
            expect(purchase_2.affiliate_credit).to be_nil
            expect(purchase_2.fee_cents).to eq(300)
            expect(product_2.user.unpaid_balance_cents).to eq(1400)
          end
        end

        context "when 'affiliate_id' is passed in as a request parameter" do
          before(:each) do
            multiple_purchase_params[:line_items][0][:affiliate_id] = direct_affiliate.external_id_numeric
            multiple_purchase_params[:line_items][1][:affiliate_id] = direct_affiliate.external_id_numeric
          end

          context "when a matching affiliate cookie exists" do
            it "doesn't make use of 'affiliate_id' from params" do
              expect(controller).not_to receive(:affiliate_from_params).with(product_1, anything)

              expect do
                post :create, params: multiple_purchase_params
              end.to change { Purchase.successful.count }.by(2)

              affiliate_purchase = Purchase.second_to_last
              expect(affiliate_purchase.affiliate_credit_cents).to eq(79)
              expect(affiliate_purchase.affiliate).to eq(direct_affiliate)
            end
          end

          context "when a matching affiliate cookie doesn't exist" do
            before(:each) do
              cookies.delete "#{Affiliate::AFFILIATE_COOKIE_NAME_PREFIX}#{direct_affiliate.external_id}"
            end

            it "fetches affiliate using the 'affiliate_id' parameter" do
              expect(controller).to receive(:affiliate_from_params).with(product_1, anything).and_call_original
              allow(controller).to receive(:affiliate_from_params).with(product_2, anything).and_call_original

              expect do
                post :create, params: multiple_purchase_params
              end.to change { Purchase.successful.count }.by(2)

              affiliate_purchase = Purchase.second_to_last
              expect(affiliate_purchase.affiliate_credit_cents).to eq(79)
              expect(affiliate_purchase.affiliate).to eq(direct_affiliate)
            end

            context "when the 'affiliate_id' parameter doesn't match with the product's affiliates" do
              let(:another_direct_affiliate) { create(:direct_affiliate, affiliate_user:, affiliate_basis_points: 1500) }

              it "doesn't credit the affiliate commission" do
                multiple_purchase_params[:line_items][0][:affiliate_id] = another_direct_affiliate.external_id_numeric
                multiple_purchase_params[:line_items][1][:affiliate_id] = another_direct_affiliate.external_id_numeric

                expect(controller).to receive(:affiliate_from_params).with(product_1, anything).and_call_original
                allow(controller).to receive(:affiliate_from_params).with(product_2, anything).and_call_original

                expect do
                  post :create, params: multiple_purchase_params
                end.to change { Purchase.successful.count }.by(2)

                purchase = Purchase.last
                expect(purchase.affiliate_credit_cents).to eq(0)
                expect(purchase.affiliate).to be_nil
              end
            end
          end
        end
      end

      describe "test purchases" do
        before do
          sign_in product_2.user
        end

        it "creates a successful test purchase" do
          expect do
            expect do
              post :create, params: multiple_purchase_params
              expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to be(true)
              expect(response.parsed_body["line_items"]["unique-id-1"]["test"]).to be(true)
              expect(response.parsed_body["can_buyer_sign_up"]).to eq(false)
            end.to change(Purchase.test_successful, :count).by(2)
          end.to change(Order, :count).by(1)

          expect(Purchase.last.purchase_state).to eq "test_successful"
        end

        it "sends the ping webhook" do
          WebMock.stub_request(:post, "http://example.com").with(body: "https://news.ycombinator.com")
          product_1.user.update_attribute(:notification_endpoint, "http://example.com")
          product_2.user.update_attribute(:notification_endpoint, "http://example.com")

          post :create, params: multiple_purchase_params

          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(Purchase.second_to_last.id, nil)
          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(Purchase.last.id, nil)
        end

        it "sends the correct receipt" do
          redirect_1 = create(:url_redirect, link: product_1)
          redirect_2 = create(:url_redirect, link: product_2)

          allow(UrlRedirect).to receive(:create!).and_return(redirect_1)
          allow(UrlRedirect).to receive(:create!).and_return(redirect_2)

          expect(CustomerMailer).not_to receive(:receipt)

          expect { post :create, params: multiple_purchase_params }.to change { Charge.count }.by(1)

          expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(Charge.last.id)
        end

        describe "subscriptions" do
          let(:product_2) { create(:subscription_product) }

          it "creates a successful purchase" do
            price = product_2.prices.alive.first
            multiple_purchase_params[:line_items][1].merge!(
              price_id: price.external_id,
              perceived_price_cents: price.price_cents
            )
            expect do
              post :create, params: multiple_purchase_params
            end.to change { product_2.subscriptions.count }.by(1)
            expect(Subscription.last.original_purchase.purchase_state).to eq "test_successful"
          end
        end

        describe "preorder" do
          let(:product_2) { create(:product, price_cents: price_2, is_in_preorder_state: true) }

          before do
            create(:preorder_link, link: product_2)
          end

          it "creates a successful purchase" do
            multiple_purchase_params[:line_items][1][:is_preorder] = true
            expect do
              post :create, params: multiple_purchase_params
            end.to change(Preorder, :count).by(1)
            expect(Purchase.last.purchase_state).to eq "test_preorder_successful"
          end
        end
      end

      describe "preorders" do
        let(:product_1) { create(:product, price_cents: price_1, is_in_preorder_state: true) }
        let(:product_2) { create(:product, price_cents: price_2, is_in_preorder_state: true) }

        before do
          create(:preorder_link, link: product_1)
          create(:preorder_link, link: product_2)

          multiple_purchase_params[:line_items][0][:is_preorder] = true
          multiple_purchase_params[:line_items][1][:is_preorder] = true
        end

        describe "logged in" do
          describe "saved card" do
            let(:user) { create(:user) }

            before do
              sign_in user
            end

            it "assigns the new credit card to the logged in user" do
              post :create, params: multiple_purchase_params

              expect(response.parsed_body["can_buyer_sign_up"]).to eq(false)

              preorder = Preorder.last
              purchase = Purchase.last

              expect(preorder.state).to eq "authorization_successful"
              expect(preorder.authorization_purchase).to eq purchase
              expect(preorder.authorization_purchase.credit_card).to be_present
              expect(purchase.purchase_state).to eq "preorder_authorization_successful"
              expect(purchase.url_redirect).to_not be_present
              expect(purchase.purchaser).to eq user
              expect(user.reload.credit_card).to eq preorder.authorization_purchase.credit_card
              expect(product_2.user.balances.empty?).to be(true)
            end

            it "uses the buyer's existing credit card" do
              user.credit_card = create(:credit_card)
              user.save!
              post :create, params: multiple_purchase_params

              preorder = Preorder.last
              purchase = Purchase.last

              expect(preorder.state).to eq "authorization_successful"
              expect(preorder.authorization_purchase).to eq purchase
              expect(preorder.authorization_purchase.credit_card).to be_present
              expect(purchase.purchase_state).to eq "preorder_authorization_successful"
              expect(purchase.url_redirect).to_not be_present
              expect(purchase.purchaser).to eq user
              expect(user.reload.credit_card).to eq preorder.authorization_purchase.credit_card

              expect(product_2.user.balances.empty?).to be(true)
            end
          end
        end
      end

      describe "gift purchases" do
        before do
          multiple_purchase_params.merge!(
            is_gift: "true",
            giftee_email: "giftee@gumroad.com",
            gift_note: "Happy birthday!"
          )
        end

        it "creates the gift" do
          expect do
            expect do
              expect do
                expect(Purchase::CreateService).to receive(:new).with(
                  product: product_1,
                  params: hash_including(
                    gift: { gift_note: "Happy birthday!", giftee_email: "giftee@gumroad.com" },
                    is_gift: "true"
                  ),
                  buyer: anything
                ).and_call_original
                expect(Purchase::CreateService).to receive(:new).with(
                  product: product_2,
                  params: hash_including(
                    gift: { gift_note: "Happy birthday!", giftee_email: "giftee@gumroad.com" },
                    is_gift: "true"
                  ),
                  buyer: anything
                ).and_call_original

                post :create, params: multiple_purchase_params

                expect(response.parsed_body["can_buyer_sign_up"]).to eq(true)

                purchase_1 = Purchase.successful.first
                expect(purchase_1.is_gift_sender_purchase).to be(true)

                gift = purchase_1.gift_given
                expect(gift).to be_successful
                expect(gift.gift_note).to eq "Happy birthday!"
                expect(gift.giftee_email).to eq "giftee@gumroad.com"
                expect(gift.gifter_email).to eq "buyer@gumroad.com"

                giftee_purchase = gift.giftee_purchase
                expect(giftee_purchase.purchase_state).to eq "gift_receiver_purchase_successful"
                expect(giftee_purchase.is_gift_sender_purchase).to be false
                expect(giftee_purchase.is_gift_receiver_purchase).to be true
                expect(giftee_purchase.price_cents).to eq 0
                expect(giftee_purchase.total_transaction_cents).to eq 0
                expect(giftee_purchase.displayed_price_cents).to eq 0

                purchase_2 = Purchase.successful.last
                expect(purchase_2.is_gift_sender_purchase).to be(true)

                gift = purchase_2.gift_given
                expect(gift).to be_successful
                expect(gift.gift_note).to eq "Happy birthday!"
                expect(gift.giftee_email).to eq "giftee@gumroad.com"
                expect(gift.gifter_email).to eq "buyer@gumroad.com"

                giftee_purchase = gift.giftee_purchase
                expect(giftee_purchase.purchase_state).to eq "gift_receiver_purchase_successful"
                expect(giftee_purchase.is_gift_sender_purchase).to be false
                expect(giftee_purchase.is_gift_receiver_purchase).to be true
                expect(giftee_purchase.price_cents).to eq 0
                expect(giftee_purchase.total_transaction_cents).to eq 0
                expect(giftee_purchase.displayed_price_cents).to eq 0
              end.to change(Purchase.successful, :count).by(2)
            end.to change(Gift, :count).by(2)
          end.to change(Order, :count).by(1)

          expect(Order.last.purchases.count).to eq(2)
          expect(Order.last.purchases.successful.count).to eq(2)
        end

        it "does not allow sign-up when gifter already has an account set up" do
          create(:user, email: "buyer@gumroad.com")

          expect(Purchase::CreateService).to receive(:new).with(
            product: product_1,
            params: hash_including(
              gift: { gift_note: "Happy birthday!", giftee_email: "giftee@gumroad.com" },
              is_gift: "true"
            ),
            buyer: anything
          ).and_call_original
          expect(Purchase::CreateService).to receive(:new).with(
            product: product_2,
            params: hash_including(
              gift: { gift_note: "Happy birthday!", giftee_email: "giftee@gumroad.com" },
              is_gift: "true"
            ),
            buyer: anything
          ).and_call_original

          post :create, params: multiple_purchase_params

          expect(response.parsed_body["can_buyer_sign_up"]).to eq(false)
        end

        it "passes through giftee_id when provided instead of email" do
          user = create(:user, email: "sahil@gumroad.com")

          multiple_purchase_params.delete(:giftee_email)
          multiple_purchase_params.merge!(giftee_id: user.external_id)

          expect(Purchase::CreateService).to receive(:new).with(
            product: product_1,
            params: hash_including(
              gift: { gift_note: "Happy birthday!", giftee_id: user.external_id },
              is_gift: "true"
            ),
            buyer: anything
          ).and_call_original
          expect(Purchase::CreateService).to receive(:new).with(
            product: product_2,
            params: hash_including(
              gift: { gift_note: "Happy birthday!", giftee_id: user.external_id },
              is_gift: "true"
            ),
            buyer: anything
          ).and_call_original

          post :create, params: multiple_purchase_params
        end
      end

      describe "saved cards" do
        let(:payment_params) { {} }
        let(:credit_card) { create(:credit_card) }
        let(:user) { create(:user, credit_card:) }

        before do
          sign_in user
        end

        it "allows the purchase with no cc creds" do
          expect do
            post :create, params: multiple_purchase_params
            expect(response.parsed_body["can_buyer_sign_up"]).to eq(false)
          end.to change(Purchase.successful, :count).by(2)
        end
      end

      it "stores the ip address of the client" do
        post :create, params: multiple_purchase_params
        expect(Purchase.last.ip_address).to_not be(nil)
      end

      describe "failed purchase" do
        let(:payment_params) { StripePaymentMethodHelper.decline.to_stripejs_params }

        it "does not error with empty card country string" do
          allow_any_instance_of(Purchase).to receive(:card_country).and_return("")

          expect do
            post :create, params: multiple_purchase_params
          end.to change(Purchase.failed, :count).by(2)

          expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(false)
          expect(response.parsed_body["line_items"]["unique-id-0"]["card_country"]).to be_nil
          expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to be(false)
          expect(response.parsed_body["line_items"]["unique-id-1"]["card_country"]).to be_nil
        end
      end

      describe "successful purchase" do
        it "sets the proper payment attributes" do
          post :create, params: multiple_purchase_params

          purchase_1 = Purchase.second_to_last
          expect(purchase_1.purchase_state).to eq "successful"
          expect(purchase_1.card_country).to be_present
          expect(purchase_1.stripe_fingerprint).to be_present
          expect(purchase_1.succeeded_at).to be_present

          purchase_2 = Purchase.last
          expect(purchase_2.purchase_state).to eq "successful"
          expect(purchase_2.card_country).to be_present
          expect(purchase_2.stripe_fingerprint).to be_present
          expect(purchase_2.succeeded_at).to be_present
        end
      end

      describe "is_mobile" do
        it "sets to false if not mobile" do
          @request.user_agent = "Some Desktopish User Agent"
          post :create, params: multiple_purchase_params
          expect(Purchase.second_to_last.is_mobile).to be(false)
          expect(Purchase.last.is_mobile).to be(false)
        end

        it "sets to true if mobile" do
          @request.user_agent = "Some Mobile User Agent"
          post :create, params: multiple_purchase_params
          expect(Purchase.second_to_last.is_mobile).to be(true)
          expect(Purchase.last.is_mobile).to be(true)
        end
      end

      describe "url_parameters" do
        before do
          product_2.user.update!(notification_endpoint: "https://example.com")

          product_2.update!(custom_permalink: "test_custom_permalink", price_cents: 0)
          multiple_purchase_params[:url_parameters] = "{}"
        end

        context "when url_parameters is empty and referrer contains product URL with query string" do
          context "when query string param contains one value" do
            it "sets url_parameters from referrer" do
              multiple_purchase_params[:referrer] = short_link_url(product_2.custom_permalink, test: 1234, host: UrlService.domain_with_protocol)

              post :create, params: multiple_purchase_params

              expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(Purchase.last.id, { "test" => "1234" })
            end
          end

          context "when query string param contains multiple values" do
            it "sets url_parameters from referrer with values in an array" do
              multiple_purchase_params[:referrer] = short_link_url(product_2.custom_permalink, host: UrlService.domain_with_protocol) + "?test=1234&test=5678"

              post :create, params: multiple_purchase_params

              expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(Purchase.last.id, { "test" => ["1234", "5678"] })
            end
          end

          context "when product URL is a subdomain URL" do
            it "sets url_parameters from referrer" do
              multiple_purchase_params[:referrer] = "#{product_2.long_url}?test=1234"

              post :create, params: multiple_purchase_params

              expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(Purchase.last.id, { "test" => "1234" })
            end
          end
        end

        context "when url_paramers is empty and referrer doesn't contain a valid product url" do
          it "doesn't set url_parameters from referrer" do
            multiple_purchase_params[:referrer] = short_link_url(product_2.custom_permalink, test: 1234, host: "example-invalid-domain.com")

            post :create, params: multiple_purchase_params

            expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(Purchase.last.id, nil)
          end
        end

        context "when url_parameters is set and referrer contains product URL with query string" do
          it "sends the ping using the configured url_parameters" do
            multiple_purchase_params[:referrer] = "#{product_2.long_url}?test=1234"
            multiple_purchase_params[:url_parameters] = { test: "abcd" }.to_json

            post :create, params: multiple_purchase_params

            expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(Purchase.last.id, { "test" => "abcd" })
          end
        end
      end

      describe "when it creates a url redirect" do
        it "returns the url_redirect location in the response" do
          post :create, params: multiple_purchase_params
          expect(response.parsed_body["line_items"]["unique-id-0"]["content_url"]).to eq UrlRedirect.second_to_last.download_page_url
          expect(response.parsed_body["line_items"]["unique-id-1"]["content_url"]).to eq UrlRedirect.last.download_page_url
        end

        it "returns url_redirect for 0+ links" do
          product_1.update!(price_range: "0+")
          product_2.update!(price_range: "0+")

          multiple_purchase_params[:line_items][0].merge!(perceiver_price_cents: 0, price_range: "0")
          multiple_purchase_params[:line_items][1].merge!(perceiver_price_cents: 0, price_range: "0")

          post :create, params: multiple_purchase_params
          expect(response.parsed_body["line_items"]["unique-id-0"]["content_url"]).to eq UrlRedirect.second_to_last.download_page_url
          expect(response.parsed_body["line_items"]["unique-id-1"]["content_url"]).to eq UrlRedirect.last.download_page_url
        end
      end

      describe "remember who made the purchase" do
        it "tracks a valid user purchase" do
          sign_in create(:user)

          post :create, params: multiple_purchase_params

          expect(Purchase.second_to_last.purchaser).to be_present
          expect(Purchase.second_to_last.session_id).to be_present

          expect(Purchase.last.purchaser).to be_present
          expect(Purchase.last.session_id).to be_present
        end

        it "tracks a valid anonymous purchase" do
          post :create, params: multiple_purchase_params

          expect(Purchase.second_to_last.purchaser).to be_nil
          expect(Purchase.second_to_last.session_id).to be_present

          expect(Purchase.last.purchaser).to be_nil
          expect(Purchase.last.session_id).to be_present
        end

        it "sets the purchaser if buyer is logged out user" do
          user = create(:user)

          post :create, params: multiple_purchase_params.merge(email: user.email)
          expect(Purchase.second_to_last.purchaser).to eq(user)
          expect(Purchase.last.purchaser).to eq(user)
        end

        it "does not set the purchaser if buyer is seller" do
          post :create, params: multiple_purchase_params.merge(email: product_2.user.email)

          expect(Purchase.second_to_last.purchaser).to be_nil
          expect(Purchase.last.purchaser).to be_nil
        end
      end

      describe "payment options" do
        let(:payment_params) { StripePaymentMethodHelper.decline.to_stripejs_params }

        it "fails the purchase gracefully if the credit card is bad, even in production where tell_chat fully runs" do
          allow(Rails.env).to receive(:production?).and_return(true)
          # Assume reCAPTCHA passes
          allow_any_instance_of(OrdersController).to receive(:valid_recaptcha_response_and_hostname?).and_return(true)

          expect do
            post :create, params: multiple_purchase_params

            expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(false)
            expect(response.parsed_body["line_items"]["unique-id-0"]["error_message"]).to be_present

            expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to be(false)
            expect(response.parsed_body["line_items"]["unique-id-1"]["error_message"]).to be_present
          end.to change(Purchase.failed, :count).by(2)
        end
      end

      describe "repeat purchases" do
        it "does not allow a repeat purchase from the same user" do
          expect do
            post :create, params: multiple_purchase_params
          end.to change(Purchase.successful, :count).by(2)

          # Verify that the double-submit fails
          expect do
            post :create, params: multiple_purchase_params

            expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(false)
            expect(response.parsed_body["line_items"]["unique-id-0"]["error_message"]).to be_present

            expect(response.parsed_body["line_items"]["unique-id-1"]["success"]).to be(false)
            expect(response.parsed_body["line_items"]["unique-id-1"]["error_message"]).to be_present
          end.not_to change(Purchase.successful, :count)
        end
      end

      describe "cookies" do
        context "when cookies are turned off" do
          before do
            cookies[:_gumroad_guid] = nil
          end

          context "when all purchases are free" do
            before do
              product_1.update!(price_range: "0+")
              product_2.update!(price_range: "0+")

              multiple_purchase_params[:line_items][0].merge!(perceived_price_cents: 0, price_range: "0")
              multiple_purchase_params[:line_items][1].merge!(perceived_price_cents: 0, price_range: "0")
            end

            it "succeeds" do
              expect do
                post :create, params: multiple_purchase_params
              end.to change(Purchase.successful, :count).by(2)
            end
          end

          context "when at least one paid purchase" do
            before do
              product_1.update!(price_range: "0+")

              multiple_purchase_params[:line_items][0].merge!(perceived_price_cents: 0, price_range: "0")
            end

            it "blocks the request" do
              expect do
                post :create, params: multiple_purchase_params

                expect(response.parsed_body["success"]).to be(false)
                expect(response.parsed_body["can_buyer_sign_up"]).to be_nil
                expect(response.parsed_body["error_message"]).to eq("Cookies are not enabled on your browser. Please enable cookies and refresh this page before continuing.")
              end.not_to change(Purchase.successful, :count)
            end
          end

          it "blocks the request" do
            expect do
              post :create, params: multiple_purchase_params

              expect(response.parsed_body["success"]).to be(false)
              expect(response.parsed_body["can_buyer_sign_up"]).to be_nil
              expect(response.parsed_body["error_message"]).to eq("Cookies are not enabled on your browser. Please enable cookies and refresh this page before continuing.")
            end.not_to change(Purchase.successful, :count)
          end
        end
      end

      describe "bots" do
        it "detects the bot and does not create a purchase" do
          @request.env["HTTP_USER_AGENT"] = "EventMachine HttpClient"
          expect do
            post :create, params: multiple_purchase_params
            expect(response.parsed_body["success"]).to be(true) # fooling the bots ;)
          end.to change(Purchase, :count).by(0)
        end
      end

      describe "purchase attribution to UTM links", :sidekiq_inline do
        let(:browser_guid) { "123" }

        before do
          product_2.update!(user: seller_2)
          cookies[:_gumroad_guid] = browser_guid
          Feature.activate(:utm_links)
        end

        it "attributes all successful purchases in the order" do
          utm_link = create(:utm_link, seller: product_1.user)
          utm_link_visit = create(:utm_link_visit, utm_link:, browser_guid:)

          expect do
            post :create, params: multiple_purchase_params
          end.to change { utm_link.utm_link_driven_sales.count }.by(1)

          order = Order.last
          utm_link_driven_sales = utm_link.utm_link_driven_sales
          expect(utm_link_driven_sales.pluck(:purchase_id)).to match_array(order.purchases.successful.where(link: product_1).pluck(:id))
          expect(utm_link_driven_sales.pluck(:utm_link_visit_id)).to all(eq(utm_link_visit.id))
        end

        it "only attributes successful purchases when some fail" do
          utm_link1 = create(:utm_link, seller: product_1.user)
          utm_link2 = create(:utm_link, seller: product_2.user)
          utm_link1_visit = create(:utm_link_visit, utm_link: utm_link1, browser_guid:)
          create(:utm_link_visit, utm_link: utm_link2, browser_guid:)

          country_field = create(:custom_field, name: "country", required: true)
          product_2.custom_fields << country_field

          expect do
            post :create, params: multiple_purchase_params
          end.to change { utm_link1.utm_link_driven_sales.count }.by(1)
              .and change { Purchase.successful.count }.by(1)

          purchase = Purchase.successful.last
          expect(purchase.link).to eq(product_1)
          expect(utm_link1.utm_link_driven_sales.sole.utm_link_visit).to eq(utm_link1_visit)
          expect(utm_link1.utm_link_driven_sales.sole.purchase_id).to eq(purchase.id)
          expect(utm_link2.utm_link_driven_sales.count).to eq(0)
        end
      end
    end

    context "when purchaser's email is empty" do
      let(:purchase_params) do
        {
          line_items: [{
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            perceived_price_cents: price_1,
            quantity: 1
          }]
        }.merge(common_purchase_params)
      end

      it "saves the purchase email as purchaser's unconfirmed email" do
        user = create(:user, confirmed_at: nil)
        user.email = ""
        user.save(validate: false)
        sign_in user
        expect_any_instance_of(User).to receive(:send_confirmation_instructions)

        post :create, params: purchase_params

        expect(user.reload.email).to eq("")
        expect(user.reload.unconfirmed_email).to eq(purchase_params[:email])
      end

      it "does not update purchaser's email if an account already exists with the email" do
        create(:user, email: purchase_params[:email])
        user = create(:user)
        user.email = ""
        user.save(validate: false)
        sign_in user
        expect_any_instance_of(User).to_not receive(:send_confirmation_instructions)

        post :create, params: purchase_params

        expect(user.reload.email).to eq("")
        expect(user.reload.unconfirmed_email).to eq(nil)
      end

      it "does not update purchaser's email if current email is not empty" do
        user = create(:user)
        existing_email = user.email
        sign_in user
        expect_any_instance_of(User).to_not receive(:send_confirmation_instructions)

        post :create, params: purchase_params

        expect(user.reload.email).to eq(existing_email)
        expect(user.reload.unconfirmed_email).to eq(nil)
      end
    end
  end

  describe "POST confirm" do
    let(:chargeable) { build(:chargeable, card: StripePaymentMethodHelper.success_sca_not_required) }
    let(:order) { create(:order) }
    let(:purchase) { create(:purchase_in_progress, chargeable:, was_product_recommended: true, recommended_by: "discover") }

    before do
      order.purchases << purchase
      purchase.process!
    end

    context "when purchase was marked as failed" do
      before do
        purchase.mark_failed!
      end

      it "renders an error" do
        post :confirm, params: {
          id: order.external_id
        }

        expect(ChargeProcessor).not_to receive(:confirm_payment_intent!)

        line_items = response.parsed_body["line_items"]
        expect(line_items.values.first["success"]).to eq(false)
        expect(line_items.values.first["error_message"]).to eq("There is a temporary problem, please try again (your card was not charged).")
        expect(SendChargeReceiptJob.jobs.size).to eq(0)
      end
    end

    context "when SCA fails" do
      it "marks purchase as failed and renders an error" do
        post :confirm, params: {
          id: order.external_id,
          stripe_error: {
            code: "invalid_request_error",
            message: "We are unable to authenticate your payment method."
          }
        }

        expect(purchase.reload.purchase_state).to eq("failed")

        line_items = response.parsed_body["line_items"]
        expect(line_items.values.first["success"]).to eq(false)
        expect(line_items.values.first["error_message"]).to eq("We are unable to authenticate your payment method.")
        expect(SendChargeReceiptJob.jobs.size).to eq(0)
      end
    end

    context "when confirmation fails" do
      before do
        allow(ChargeProcessor).to receive(:confirm_payment_intent!).and_raise(ChargeProcessorUnavailableError)
      end

      it "marks purchase as failed and renders an error" do
        post :confirm, params: { id: order.external_id }

        expect(purchase.reload.purchase_state).to eq("failed")

        line_items = response.parsed_body["line_items"]
        expect(line_items.values.first["success"]).to eq(false)
        expect(line_items.values.first["error_message"]).to eq("There is a temporary problem, please try again (your card was not charged).")
        expect(SendChargeReceiptJob.jobs.size).to eq(0)
      end

      it "does not delete the bundle cookie" do
        cookies["gumroad-bundle"] = "bundle cookie"

        post :confirm, params: { id: order.external_id }
        cookies.update(response.cookies)

        expect(cookies["gumroad-bundle"]).to be_present
      end
    end

    context "when confirmation succeeds" do
      before do
        allow_any_instance_of(Stripe::PaymentIntent).to receive(:confirm)
      end

      it "confirms the purchases in the order" do
        expect(purchase.reload.successful?).to eq(false)
        expect(Purchase::ConfirmService).to receive(:new).with(hash_including(purchase:)).and_call_original

        post :confirm, params: { id: order.external_id }

        line_items = response.parsed_body["line_items"]
        expect(line_items.values.first["success"]).to eq(true)
        expect(line_items.values.first).to eq(purchase.reload.purchase_response.as_json)

        expect(purchase.reload.successful?).to eq(true)
      end

      context "when the purchase doesn't belong to a Charge" do
        it "does not send the charge receipt" do
          expect(purchase.reload.successful?).to eq(false)
          expect(Purchase::ConfirmService).to receive(:new).with(hash_including(purchase:)).and_call_original

          post :confirm, params: { id: order.external_id }
          expect(purchase.reload.successful?).to eq(true)
          expect(SendChargeReceiptJob.jobs.size).to eq(0)
        end
      end

      context "when the purchase belongs to a Charge" do
        let!(:charge) { create(:charge, order:, purchases: [purchase]) }

        it "sends the charge receipt" do
          expect(purchase.reload.successful?).to eq(false)
          expect(Purchase::ConfirmService).to receive(:new).with(hash_including(purchase:)).and_call_original

          post :confirm, params: { id: order.external_id }
          expect(purchase.reload.successful?).to eq(true)
          expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge.id)
        end
      end
    end
  end
end
