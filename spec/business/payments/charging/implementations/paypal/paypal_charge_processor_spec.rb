# frozen_string_literal: true

require "spec_helper"
# The VCRs for this charge processor are recorded from manually setup scenarios
# DO NOT delete VCRs in case you are re-recording en masse
#
# Steps to setup an express checkout to record a VCR our of:
#  - Create a product (non recurring charge, non pre order) locally with the desired amount required to auth (thorugh the rails server)
#  - Purchase the product w/o logging in as any user in the desired price-affecting configuration and authenticate through the PayPal lightbox
#  - After this point, you can use the PayPal express checkout token for all further operations available in the charge processor
#    Manually setup the desired scenario.

describe PaypalChargeProcessor, :vcr do
  let(:paypal_auth_token) do
    "Bearer A21AAI9v6NTs3Y42Ufo-5Q-cskFZtTLkOodRO1uJQvdaWnsbiCt078vvzYnSy5X1gLFwGZIyhtT6D_EUZyyyp_YjB9CudeK7w"
  end

  before do
    allow_any_instance_of(PaypalPartnerRestCredentials).to receive(:auth_token).and_return(paypal_auth_token)
  end

  describe ".charge_processor_id" do
    it "returns 'paypal'" do
      expect(described_class.charge_processor_id).to eq "paypal"
    end
  end

  describe "PayPal payment events handler" do
    describe "non payment event determined by the invoice field existing" do
      before do
        raw_payload =
          "payment_type=echeck&payment_date=Sun%20May%2024%202015%2014%3A32%3A31%20GMT-0700%20%28PDT%29&payment_status=Reversed&" \
          "payer_status=verified&first_name=John&last_name=Smith&payer_email=buyer%40paypalsandbox.com&payer_id=TESTBUYERID01&address_name=John%20Smith&address_country=United%20States&" \
          "address_country_code=US&address_zip=95131&address_state=CA&address_city=San%20Jose&address_street=123%20any%20street&business=seller%40paypalsandbox.com&" \
          "receiver_email=seller%40paypalsandbox.com&receiver_id=seller%40paypalsandbox.com&residence_country=US&item_name=something&item_number=AK-1234&quantity=1&" \
          "shipping=3.04&tax=2.02&mc_currency=USD&mc_fee=0.44&mc_gross=12.34&mc_gross1=12.34&txn_type=web_accept&txn_id=995288809&notify_version=2.1&parent_txn_id=SOMEPRIORTXNID002&" \
          "reason_code=chargeback&receipt_ID=3012-5109-3782-6103&custom=xyz123&test_ipn=1&verify_sign=AFcWxV21C7fd0v3bYYYRCpSSRl31A4SYxlXZ9IdB.iATdIIByT4aW.Qa"

        @payload = Rack::Utils.parse_nested_query(raw_payload)
      end
      it "does not process it and raises an error" do
        expect do
          described_class.handle_paypal_event(@payload)
        end.to raise_error(RuntimeError)
      end
    end

    describe "payment event" do
      before do
        @purchase = create(:purchase_with_balance, id: 1001)
        allow_any_instance_of(Purchase).to receive(:fight_chargeback).and_return(true)
      end

      describe "reversal and reversal cancelled events" do
        describe "reversal event" do
          before do
            raw_payload =
              "payment_type=echeck&payment_date=Sun%20May%2024%202015%2014%3A32%3A31%20GMT-0700%20%28PDT%29&payment_status=Reversed&" \
              "payer_status=verified&first_name=John&last_name=Smith&payer_email=buyer%40paypalsandbox.com&payer_id=TESTBUYERID01&address_name=John%20Smith&address_country=United%20States&" \
              "address_country_code=US&address_zip=95131&address_state=CA&address_city=San%20Jose&address_street=123%20any%20street&business=seller%40paypalsandbox.com&" \
              "receiver_email=seller%40paypalsandbox.com&receiver_id=seller%40paypalsandbox.com&residence_country=US&item_name=something&item_number=AK-1234&quantity=1&" \
              "shipping=-3.04&tax=-2.02&mc_currency=USD&mc_fee=-0.44&mc_gross=-12.34&mc_gross1=-12.34&txn_type=web_accept&txn_id=995288809&notify_version=2.1&parent_txn_id=SOMEPRIORTXNID002&" \
              "reason_code=chargeback&receipt_ID=3012-5109-3782-6103&custom=xyz123&invoice=D7lNKK8L-urz8D3awchsUA%3D%3D&test_ipn=1&verify_sign=AFcWxV21C7fd0v3bYYYRCpSSRl31A4SYxlXZ9IdB.iATdIIByT4aW.Qa"

            @payload = Rack::Utils.parse_nested_query(raw_payload)
          end

          it "handles a chargeback message form PayPal" do
            expect(@purchase.chargeback_date).to be(nil)

            described_class.handle_paypal_event(@payload)

            @purchase.reload
            expect(@purchase.chargeback_date).to_not be(nil)
            expect(@purchase.chargeback_reversed).to be(false)
            expect(@purchase.chargeback_date).to eq(@payload["payment_date"])
          end

          it "tells the charge processor that a dispute was created" do
            original_handle_event = ChargeProcessor.method(:handle_event)
            expect(ChargeProcessor).to(receive(:handle_event) do |charge_event|
              expect(charge_event).to be_a(ChargeEvent)
              expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_FORMALIZED)
              expect(charge_event.flow_of_funds).to be(nil)
              original_handle_event.call(charge_event)
            end)
            described_class.handle_paypal_event(@payload)
          end
        end

        describe "reversal cancelled event" do
          let(:paypal_payment_info) do
            paypal_payment_info = PayPal::SDK::Merchant::DataTypes::PaymentInfoType.new
            paypal_payment_info.PaymentStatus = PaypalApiPaymentStatus::REFUNDED
            paypal_payment_info.GrossAmount.value = "10.00"
            paypal_payment_info.GrossAmount.currencyID = "USD"
            paypal_payment_info.FeeAmount.value = "1.00"
            paypal_payment_info.FeeAmount.currencyID = "USD"
            paypal_payment_info
          end

          let(:paypal_payer_info) do
            paypal_payer_info = PayPal::SDK::Merchant::DataTypes::PayerInfoType.new
            paypal_payer_info.Payer = "paypal-buyer@gumroad.com"
            paypal_payer_info.PayerID = "sample-fingerprint-source"
            paypal_payer_info.PayerCountry = Compliance::Countries::USA.alpha2
            paypal_payer_info
          end

          before do
            raw_payload =
              "payment_type=instant&payment_date=Sun%20May%2024%202015%2015%3A04%3A11%20GMT-0700%20%28PDT%29&payment_status=Canceled_Reversal&" \
              "address_status=confirmed&payer_status=verified&first_name=John&last_name=Smith&payer_email=buyer%40paypalsandbox.com&payer_id=TESTBUYERID01&" \
              "address_name=John%20Smith&address_country=United%20States&address_country_code=US&address_zip=95131&address_state=CA&address_city=San%20Jose&" \
              "address_street=123%20any%20street&business=seller%40paypalsandbox.com&receiver_email=seller%40paypalsandbox.com&receiver_id=seller%40paypalsandbox.com&residence_country=US&" \
              "item_name=something&item_number=AK-1234&quantity=1&shipping=3.04&tax=2.02&mc_currency=USD&mc_fee=0.44&mc_gross=12.34&mc_gross1=12.34&txn_type=web_accept&txn_id=694541630&" \
              "notify_version=2.1&parent_txn_id=PARENT_TXN_ID&reason_code=other&custom=xyz123&invoice=D7lNKK8L-urz8D3awchsUA%3D%3D&test_ipn=1&" \
              "verify_sign=AFcWxV21C7fd0v3bYYYRCpSSRl31A48M..jE7GasP8rDsyMNp6bZuihz"

            @payload = Rack::Utils.parse_nested_query(raw_payload)

            @purchase.chargeback_date = Time.current
            @purchase.save!
          end

          before(:each) do
            @mock_paypal_charge = PaypalCharge.new(paypal_transaction_id: "5SP884803B810025T",
                                                   order_api_used: false,
                                                   payment_details: {
                                                     paypal_payment_info:,
                                                     paypal_payer_info:
                                                   })
          end

          describe "reversal cancelled event" do
            describe "no transaction found for parent transaction ID" do
              it "raises a NoMethodError exception" do
                expect_any_instance_of(described_class).to receive(:get_charge).and_return(nil)

                expect do
                  described_class.handle_paypal_event(@payload)
                end.to raise_error(NoMethodError)
              end
            end

            describe "the dispute was resolved in our favor" do
              before(:each) do
                @mock_paypal_charge.paypal_payment_status = PaypalApiPaymentStatus::COMPLETED
                expect_any_instance_of(described_class).to receive(:get_charge).and_return(@mock_paypal_charge)
              end

              it "handles a chargeback reversed message form PayPal" do
                expect(@purchase.chargeback_date).to_not be(nil)

                described_class.handle_paypal_event(@payload)

                @purchase.reload
                expect(@purchase.chargeback_date).to_not be(nil)
                expect(@purchase.chargeback_reversed).to be(true)
              end

              it "tells the charge processor that a dispute was won" do
                original_handle_event = ChargeProcessor.method(:handle_event)
                expect(ChargeProcessor).to(receive(:handle_event) do |charge_event|
                                             expect(charge_event).to be_a(ChargeEvent)
                                             expect(charge_event.type).to eq(ChargeEvent::TYPE_DISPUTE_WON)
                                             expect(charge_event.flow_of_funds).to be(nil)
                                             original_handle_event.call(charge_event)
                                           end)
                described_class.handle_paypal_event(@payload)
              end
            end

            describe "the dispute was resolved in the buyers favor" do
              before(:each) do
                @mock_paypal_charge.paypal_payment_status = PaypalApiPaymentStatus::REVERSED
                expect_any_instance_of(described_class).to receive(:get_charge).and_return(@mock_paypal_charge)
              end

              it "does not send any events and do nothing" do
                expect(ChargeProcessor).to_not receive(:handle_event)
                described_class.handle_paypal_event(@payload)
              end
            end
          end
        end
      end

      describe "payment completion event" do
        before do
          raw_payload =
            "mc_gross=13.45&invoice=D7lNKK8L-urz8D3awchsUA==&auth_exp=17:15:30 Jul 23, 2015 PDT&protection_eligibility=Ineligible&payer_id=VPMPQMFE9ZCUC&" \
            "tax=0.00&payment_date=17:15:32 Jun 23, 2015 PDT&payment_status=Completed&charset=UTF-8&first_name=Jane&transaction_entity=payment&mc_fee=0.56&notify_version=3.8&" \
            "custom=&payer_status=verified&quantity=1&verify_sign=ANjcFFL6thfg3pfU8XyZ4HGhsY0wAmacmdU9K4DVg7jf-Oll2FinOurH&payer_email=travelerpalm@sbcglobal.net&" \
            "parent_txn_id=8KL149495L527372S&txn_id=2EX735004Y601032C&payment_type=instant&remaining_settle=0&auth_id=8KL149495L527372S&last_name=Wong&receiver_email=support@gumroad.com&" \
            "auth_amount=13.45&payment_fee=0.56&receiver_id=VYZJQAA368WRW&txn_type=cart&item_name=&mc_currency=USD&item_number=&residence_country=US&handling_amount=0.00&transaction_subject=&" \
            "payment_gross=13.45&auth_status=Completed&shipping=0.00&ipn_track_id=72e28fc50c6fa"

          @payload = Rack::Utils.parse_nested_query(raw_payload)
        end

        it "creates a informational charge event with the fee information" do
          @purchase.fee_cents = 0
          @purchase.save!

          described_class.handle_paypal_event(@payload)

          @purchase.reload
          expect(@purchase.chargeback_date).to be(nil)
          expect(@purchase.processor_fee_cents).to eq(56)
        end
      end

      describe "other non-completion payment event" do
        before do
          raw_payload =
            "payment_type=instant&payment_date=Tue%20May%2026%202015%2019%3A31%3A02%20GMT-0700%20%28PDT%29&payment_status=Inflight&payer_status=verified&first_name=John&" \
            "last_name=Smith&payer_email=buyer%40paypalsandbox.com&payer_id=TESTBUYERID01&address_name=John%20Smith&address_country=United%20States&address_country_code=US&" \
            "address_zip=95131&address_state=CA&address_city=San%20Jose&address_street=123%20any%20street&business=seller%40paypalsandbox.com&receiver_email=seller%40paypalsandbox.com&" \
            "receiver_id=seller%40paypalsandbox.com&residence_country=US&item_name1=something&item_number1=AK-1234&quantity=1&shipping=3.04&tax=2.02&mc_currency=USD&mc_fee=0.44&mc_gross=12.34&" \
            "mc_gross1=12.34&mc_handling=2.06&mc_handling1=1.67&mc_shipping=3.02&mc_shipping1=1.02&txn_type=cart&txn_id=899327589&notify_version=2.4&custom=xyz123&invoice=random_external_id%3D%3D&" \
            "test_ipn=1&verify_sign=AFcWxV21C7fd0v3bYYYRCpSSRl31AbXPdTVhBcCUUizimR553bDXp-Fg"

          @payload = Rack::Utils.parse_nested_query(raw_payload)
        end

        it "does not do anything" do
          expect(ActiveSupport::Notifications).to_not receive(:instrument)

          described_class.handle_paypal_event(@payload)
        end
      end

      describe "on combined charges" do
        it "creates a informational charge event with the fee information" do
          charge = create(:charge, processor_fee_cents: nil)
          charge.purchases << create(:purchase)
          expect(charge.processor_fee_cents).to be nil
          expect(charge.purchases.last.stripe_status).to be nil

          raw_payload =
            "mc_gross=13.45&invoice=#{charge.reference_id_for_charge_processors}&auth_exp=17:15:30 Jul 23, 2015 PDT&protection_eligibility=Ineligible&payer_id=VPMPQMFE9ZCUC&" \
            "tax=0.00&payment_date=17:15:32 Jun 23, 2015 PDT&payment_status=Completed&charset=UTF-8&first_name=Jane&transaction_entity=payment&mc_fee=0.56&notify_version=3.8&" \
            "custom=&payer_status=verified&quantity=1&verify_sign=ANjcFFL6thfg3pfU8XyZ4HGhsY0wAmacmdU9K4DVg7jf-Oll2FinOurH&payer_email=travelerpalm@sbcglobal.net&" \
            "parent_txn_id=8KL149495L527372S&txn_id=2EX735004Y601032C&payment_type=instant&remaining_settle=0&auth_id=8KL149495L527372S&last_name=Wong&receiver_email=support@gumroad.com&" \
            "auth_amount=13.45&payment_fee=0.56&receiver_id=VYZJQAA368WRW&txn_type=cart&item_name=&mc_currency=USD&item_number=&residence_country=US&handling_amount=0.00&transaction_subject=&" \
            "payment_gross=13.45&auth_status=Completed&shipping=0.00&ipn_track_id=72e28fc50c6fa"
          payload = Rack::Utils.parse_nested_query(raw_payload)

          described_class.handle_paypal_event(payload)

          expect(charge.reload.processor_fee_cents).to eq(56)
          expect(charge.purchases.last.stripe_status).to eq("Completed")
        end
      end
    end
  end

  describe ".handle_order_events" do
    context "when event type is CUSTOMER.DISPUTE.CREATED" do
      it "sets chargeback details on purchase" do
        event_info = { "id" => "WH-3TW20315YE525782H-3BD552601T418134F", "event_version" => "1.0", "create_time" => "2017-10-10T14:09:01.129Z", "resource_type" => "dispute", "event_type" => "CUSTOMER.DISPUTE.CREATED", "summary" => "A new dispute opened with Case # PP-D-4805PP-D-4805", "resource" => { "dispute_id" => "PP-D-4805", "create_time" => "2017-10-10T14:07:23.000Z", "update_time" => "2017-10-10T14:08:06.000Z", "disputed_transactions" => [{ "seller_transaction_id" => "6Y199803HH2987814", "seller" => { "name" => "facilitator account's Test Store" }, "items" => [{ "item_id" => "uF" }], "seller_protection_eligible" => true }], "reason" => "CREDIT_NOT_PROCESSED", "status" => "UNDER_REVIEW", "dispute_amount" => { "currency_code" => "[FILTERED]", "value" => "6.43" }, "offer" => { "buyer_requested_amount" => { "currency_code" => "[FILTERED]", "value" => "6.43" } }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/customer/disputes/PP-D-4805", "rel" => "self", "method" => "GET" }] }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-3TW20315YE525782H-3BD552601T418134F", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-3TW20315YE525782H-3BD552601T418134F/resend", "rel" => "resend", "method" => "POST" }], "foreign_webhook" => { "id" => "WH-3TW20315YE525782H-3BD552601T418134F", "event_version" => "1.0", "create_time" => "2017-10-10T14:09:01.129Z", "resource_type" => "dispute", "event_type" => "CUSTOMER.DISPUTE.CREATED", "summary" => "A new dispute opened with Case # PP-D-4805PP-D-4805", "resource" => { "dispute_id" => "PP-D-4805", "create_time" => "2017-10-10T14:07:23.000Z", "update_time" => "2017-10-10T14:08:06.000Z", "disputed_transactions" => [{ "seller_transaction_id" => "6Y199803HH2987814", "seller" => { "name" => "facilitator account's Test Store" }, "items" => [{ "item_id" => "uF" }], "seller_protection_eligible" => true }], "reason" => "CREDIT_NOT_PROCESSED", "status" => "UNDER_REVIEW", "dispute_amount" => { "currency_code" => "[FILTERED]", "value" => "6.43" }, "offer" => { "buyer_requested_amount" => { "currency_code" => "[FILTERED]", "value" => "6.43" } }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/customer/disputes/PP-D-4805", "rel" => "self", "method" => "GET" }] }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-3TW20315YE525782H-3BD552601T418134F", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-3TW20315YE525782H-3BD552601T418134F/resend", "rel" => "resend", "method" => "POST" }] } }
        purchase = create(:purchase_with_balance, id: 1001, stripe_transaction_id: "6Y199803HH2987814")
        allow_any_instance_of(Purchase).to receive(:fight_chargeback).and_return(true)

        expect(purchase.chargeback_date).to be(nil)

        described_class.handle_order_events(event_info)

        purchase.reload
        expect(purchase.chargeback_date).to_not be(nil)
        expect(purchase.chargeback_reversed).to be(false)
        expect(purchase.chargeback_date).to eq(DateTime.parse(event_info["resource"]["create_time"]))
      end

      it "raises `ChargeProcessorError` on error" do
        event_info = { "event_type" => "CUSTOMER.DISPUTE.CREATED" }
        create(:purchase_with_balance, id: 1001, stripe_transaction_id: "6Y199803HH2987814")

        expect do
          described_class.handle_order_events(event_info)
        end.to raise_error(ChargeProcessorError)
      end
    end

    context "when event type is CUSTOMER.DISPUTE.RESOLVED" do
      it "marks dispute as WON when seller wins the dispute" do
        %w[RESOLVED_SELLER_FAVOUR CANCELED_BY_BUYER DENIED].each do |dispute_outcome|
          event_info = { "id" => "WH-6TU580349K989084X-4AH939136E356570T", "event_version" => "1.0", "create_time" => "2017-10-17T01:26:40.120Z", "resource_type" => "dispute", "event_type" => "CUSTOMER.DISPUTE.RESOLVED", "summary" => "A dispute was resolved with case # PP-D-4805PP-D-4805", "resource" => { "dispute_id" => "PP-D-4805", "create_time" => "2017-10-10T14:07:23.000Z", "update_time" => "2017-10-17T01:25:10.000Z", "disputed_transactions" => [{ "seller_transaction_id" => "6Y199803HH2987814", "seller" => { "name" => "facilitator account's Test Store" }, "items" => [{ "item_id" => "uF" }], "seller_protection_eligible" => true }], "reason" => "CREDIT_NOT_PROCESSED", "status" => "RESOLVED", "dispute_amount" => { "currency_code" => "USD", "value" => "6.43" }, "dispute_outcome" => { "outcome_code" => dispute_outcome }, "offer" => { "buyer_requested_amount" => { "currency_code" => "USD", "value" => "6.43" } }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/customer/disputes/PP-D-4805", "rel" => "self", "method" => "GET" }] }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-6TU580349K989084X-4AH939136E356570T", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-6TU580349K989084X-4AH939136E356570T/resend", "rel" => "resend", "method" => "POST" }], "controller" => "foreign_webhooks", "action" => "paypal", "foreign_webhook" => { "id" => "WH-6TU580349K989084X-4AH939136E356570T", "event_version" => "1.0", "create_time" => "2017-10-17T01:26:40.120Z", "resource_type" => "dispute", "event_type" => "CUSTOMER.DISPUTE.RESOLVED", "summary" => "A dispute was resolved with case # PP-D-4805PP-D-4805", "resource" => { "dispute_id" => "PP-D-4805", "create_time" => "2017-10-10T14:07:23.000Z", "update_time" => "2017-10-17T01:25:10.000Z", "disputed_transactions" => [{ "seller_transaction_id" => "6Y199803HH2987814", "seller" => { "name" => "facilitator account's Test Store" }, "items" => [{ "item_id" => "uF" }], "seller_protection_eligible" => true }], "reason" => "CREDIT_NOT_PROCESSED", "status" => "RESOLVED", "dispute_amount" => { "currency_code" => "USD", "value" => "6.43" }, "dispute_outcome" => { "outcome_code" => "CANCELED_BY_BUYER" }, "offer" => { "buyer_requested_amount" => { "currency_code" => "USD", "value" => "6.43" } }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/customer/disputes/PP-D-4805", "rel" => "self", "method" => "GET" }] }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-6TU580349K989084X-4AH939136E356570T", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-6TU580349K989084X-4AH939136E356570T/resend", "rel" => "resend", "method" => "POST" }] } }
          purchase = create(:purchase_with_balance, stripe_transaction_id: "6Y199803HH2987814")
          purchase.update_attribute(:chargeback_date, Time.current)

          described_class.handle_order_events(event_info)
          purchase.reload
          expect(purchase.chargeback_reversed).to be(true)
          expect(purchase.dispute.won?).to be(true)
        end
      end

      it "marks dispute as LOST when seller loses the dispute" do
        event_info = { "id" => "WH-6TU580349K989084X-4AH939136E356570T", "event_version" => "1.0", "create_time" => "2017-10-17T01:26:40.120Z", "resource_type" => "dispute", "event_type" => "CUSTOMER.DISPUTE.RESOLVED", "summary" => "A dispute was resolved with case # PP-D-4805PP-D-4805", "resource" => { "dispute_id" => "PP-D-4805", "create_time" => "2017-10-10T14:07:23.000Z", "update_time" => "2017-10-17T01:25:10.000Z", "disputed_transactions" => [{ "seller_transaction_id" => "6Y199803HH2987814", "seller" => { "name" => "facilitator account's Test Store" }, "items" => [{ "item_id" => "uF" }], "seller_protection_eligible" => true }], "reason" => "CREDIT_NOT_PROCESSED", "status" => "RESOLVED", "dispute_amount" => { "currency_code" => "USD", "value" => "6.43" }, "dispute_outcome" => { "outcome_code" => "RESOLVED_BUYER_FAVOUR" }, "offer" => { "buyer_requested_amount" => { "currency_code" => "USD", "value" => "6.43" } }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/customer/disputes/PP-D-4805", "rel" => "self", "method" => "GET" }] }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-6TU580349K989084X-4AH939136E356570T", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-6TU580349K989084X-4AH939136E356570T/resend", "rel" => "resend", "method" => "POST" }], "controller" => "foreign_webhooks", "action" => "paypal", "foreign_webhook" => { "id" => "WH-6TU580349K989084X-4AH939136E356570T", "event_version" => "1.0", "create_time" => "2017-10-17T01:26:40.120Z", "resource_type" => "dispute", "event_type" => "CUSTOMER.DISPUTE.RESOLVED", "summary" => "A dispute was resolved with case # PP-D-4805PP-D-4805", "resource" => { "dispute_id" => "PP-D-4805", "create_time" => "2017-10-10T14:07:23.000Z", "update_time" => "2017-10-17T01:25:10.000Z", "disputed_transactions" => [{ "seller_transaction_id" => "6Y199803HH2987814", "seller" => { "name" => "facilitator account's Test Store" }, "items" => [{ "item_id" => "uF" }], "seller_protection_eligible" => true }], "reason" => "CREDIT_NOT_PROCESSED", "status" => "RESOLVED", "dispute_amount" => { "currency_code" => "USD", "value" => "6.43" }, "dispute_outcome" => { "outcome_code" => "CANCELED_BY_BUYER" }, "offer" => { "buyer_requested_amount" => { "currency_code" => "USD", "value" => "6.43" } }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/customer/disputes/PP-D-4805", "rel" => "self", "method" => "GET" }] }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-6TU580349K989084X-4AH939136E356570T", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-6TU580349K989084X-4AH939136E356570T/resend", "rel" => "resend", "method" => "POST" }] } }

        purchase = create(:purchase_with_balance, stripe_transaction_id: "6Y199803HH2987814")

        described_class.handle_order_events(event_info)
        purchase.reload
        expect(purchase.dispute.lost?).to be(true)
      end

      it "raises `ChargeProcessorError` on error" do
        event_info = { "event_type" => "CUSTOMER.DISPUTE.RESOLVED" }
        create(:purchase_with_balance, stripe_transaction_id: "6Y199803HH2987814")

        expect do
          described_class.handle_order_events(event_info)
        end.to raise_error(ChargeProcessorError)
      end
    end

    context "when event type is PAYMENT.CAPTURE.COMPLETED" do
      it "updates the processor fee for the purchase" do
        purchase = create(:purchase, stripe_transaction_id: "5B223658W54364539",
                                     processor_fee_cents: nil, processor_fee_cents_currency: nil)

        event_info = { "id" => "WH-2C707249AJ963352S-8WR62076K2971640M", "event_version" => "1.0", "create_time" => "2021-01-08T14:10:09.452Z", "resource_type" => "capture", "resource_version" => "2.0", "event_type" => "PAYMENT.CAPTURE.COMPLETED", "summary" => "Payment completed for GBP 1.31 GBP", "resource" => { "disbursement_mode" => "INSTANT", "amount" => { "value" => "1.31", "currency_code" => "GBP" }, "seller_protection" => { "dispute_categories" => ["ITEM_NOT_RECEIVED", "UNAUTHORIZED_TRANSACTION"], "status" => "ELIGIBLE" }, "update_time" => "2021-01-08T14:09:45Z", "create_time" => "2021-01-08T14:09:45Z", "final_capture" => true, "seller_receivable_breakdown" => { "platform_fees" => [{ "payee" => { "merchant_id" => "HU29XVVCZXNFN" }, "amount" => { "value" => "0.08", "currency_code" => "GBP" } }], "paypal_fee" => { "value" => "0.25", "currency_code" => "GBP" }, "gross_amount" => { "value" => "1.31", "currency_code" => "GBP" }, "net_amount" => { "value" => "0.98", "currency_code" => "GBP" } }, "links" => [{ "method" => "GET", "rel" => "self", "href" => "https://api.sandbox.paypal.com/v2/payments/captures/5B223658W54364539" }, { "method" => "POST", "rel" => "refund", "href" => "https://api.sandbox.paypal.com/v2/payments/captures/5B223658W54364539/refund" }, { "method" => "GET", "rel" => "up", "href" => "https://api.sandbox.paypal.com/v2/checkout/orders/0PF373004F060160X" }], "id" => "5B223658W54364539", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-2C707249AJ963352S-8WR62076K2971640M", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-2C707249AJ963352S-8WR62076K2971640M/resend", "rel" => "resend", "method" => "POST" }], "foreign_webhook" => { "id" => "WH-2C707249AJ963352S-8WR62076K2971640M", "event_version" => "1.0", "create_time" => "2021-01-08T14:10:09.452Z", "resource_type" => "capture", "resource_version" => "2.0", "event_type" => "PAYMENT.CAPTURE.COMPLETED", "summary" => "Payment completed for GBP 1.31 GBP", "resource" => { "disbursement_mode" => "INSTANT", "amount" => { "value" => "1.31", "currency_code" => "GBP" }, "seller_protection" => { "dispute_categories" => ["ITEM_NOT_RECEIVED", "UNAUTHORIZED_TRANSACTION"], "status" => "ELIGIBLE" }, "update_time" => "2021-01-08T14:09:45Z", "create_time" => "2021-01-08T14:09:45Z", "final_capture" => true, "seller_receivable_breakdown" => { "platform_fees" => [{ "payee" => { "merchant_id" => "HU29XVVCZXNFN" }, "amount" => { "value" => "0.08", "currency_code" => "GBP" } }], "paypal_fee" => { "value" => "0.25", "currency_code" => "GBP" }, "gross_amount" => { "value" => "1.31", "currency_code" => "GBP" }, "net_amount" => { "value" => "0.98", "currency_code" => "GBP" } }, "links" => [{ "method" => "GET", "rel" => "self", "href" => "https://api.sandbox.paypal.com/v2/payments/captures/5B223658W54364539" }, { "method" => "POST", "rel" => "refund", "href" => "https://api.sandbox.paypal.com/v2/payments/captures/5B223658W54364539/refund" }, { "method" => "GET", "rel" => "up", "href" => "https://api.sandbox.paypal.com/v2/checkout/orders/0PF373004F060160X" }], "id" => "5B223658W54364539", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-2C707249AJ963352S-8WR62076K2971640M", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-2C707249AJ963352S-8WR62076K2971640M/resend", "rel" => "resend", "method" => "POST" }] } }

        described_class.handle_order_events(event_info)

        purchase.reload
        expect(purchase.processor_fee_cents).to eq(25)
        expect(purchase.processor_fee_cents_currency).to eq("GBP")
      end

      it "does nothing if seller_receivable_breakdown is absent" do
        purchase = create(:purchase, stripe_transaction_id: "5B223658W54364539",
                                     processor_fee_cents: nil, processor_fee_cents_currency: nil)

        event_info = { "id" => "WH-2C707249AJ963352S-8WR62076K2971640M", "event_version" => "1.0", "create_time" => "2021-01-08T14:10:09.452Z", "resource_type" => "capture", "resource_version" => "2.0", "event_type" => "PAYMENT.CAPTURE.COMPLETED", "summary" => "Payment completed for GBP 1.31 GBP", "resource" => { "disbursement_mode" => "INSTANT", "amount" => { "value" => "1.31", "currency_code" => "GBP" }, "seller_protection" => { "dispute_categories" => ["ITEM_NOT_RECEIVED", "UNAUTHORIZED_TRANSACTION"], "status" => "ELIGIBLE" }, "update_time" => "2021-01-08T14:09:45Z", "create_time" => "2021-01-08T14:09:45Z", "final_capture" => true, "links" => [{ "method" => "GET", "rel" => "self", "href" => "https://api.sandbox.paypal.com/v2/payments/captures/5B223658W54364539" }, { "method" => "POST", "rel" => "refund", "href" => "https://api.sandbox.paypal.com/v2/payments/captures/5B223658W54364539/refund" }, { "method" => "GET", "rel" => "up", "href" => "https://api.sandbox.paypal.com/v2/checkout/orders/0PF373004F060160X" }], "id" => "5B223658W54364539", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-2C707249AJ963352S-8WR62076K2971640M", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-2C707249AJ963352S-8WR62076K2971640M/resend", "rel" => "resend", "method" => "POST" }], "foreign_webhook" => { "id" => "WH-2C707249AJ963352S-8WR62076K2971640M", "event_version" => "1.0", "create_time" => "2021-01-08T14:10:09.452Z", "resource_type" => "capture", "resource_version" => "2.0", "event_type" => "PAYMENT.CAPTURE.COMPLETED", "summary" => "Payment completed for GBP 1.31 GBP", "resource" => { "disbursement_mode" => "INSTANT", "amount" => { "value" => "1.31", "currency_code" => "GBP" }, "seller_protection" => { "dispute_categories" => ["ITEM_NOT_RECEIVED", "UNAUTHORIZED_TRANSACTION"], "status" => "ELIGIBLE" }, "update_time" => "2021-01-08T14:09:45Z", "create_time" => "2021-01-08T14:09:45Z", "final_capture" => true, "seller_receivable_breakdown" => { "platform_fees" => [{ "payee" => { "merchant_id" => "HU29XVVCZXNFN" }, "amount" => { "value" => "0.08", "currency_code" => "GBP" } }], "paypal_fee" => { "value" => "0.25", "currency_code" => "GBP" }, "gross_amount" => { "value" => "1.31", "currency_code" => "GBP" }, "net_amount" => { "value" => "0.98", "currency_code" => "GBP" } }, "links" => [{ "method" => "GET", "rel" => "self", "href" => "https://api.sandbox.paypal.com/v2/payments/captures/5B223658W54364539" }, { "method" => "POST", "rel" => "refund", "href" => "https://api.sandbox.paypal.com/v2/payments/captures/5B223658W54364539/refund" }, { "method" => "GET", "rel" => "up", "href" => "https://api.sandbox.paypal.com/v2/checkout/orders/0PF373004F060160X" }], "id" => "5B223658W54364539", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-2C707249AJ963352S-8WR62076K2971640M", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-2C707249AJ963352S-8WR62076K2971640M/resend", "rel" => "resend", "method" => "POST" }] } }

        expect do
          described_class.handle_order_events(event_info)
        end.not_to raise_error

        purchase.reload
        expect(purchase.processor_fee_cents).to be_nil
      end
    end

    context "when event is for payment capture failure" do
      before do
        allow_any_instance_of(Purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(false)

        product = create(:product, price_cents: 10_00)
        @affiliate_user = create(:affiliate_user)
        direct_affiliate = create(:direct_affiliate, affiliate_user: @affiliate_user, seller: product.user,
                                                     affiliate_basis_points: 2500, products: [product])

        @purchase = create(:purchase,
                           purchase_state: "in_progress",
                           link: product,
                           affiliate: direct_affiliate,
                           affiliate_credit_cents: 2_50,
                           charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                           stripe_transaction_id: "0TL01106E48692646")
        @purchase.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD,
                                                                         @purchase.total_transaction_cents)
        @purchase.update_balance_and_mark_successful!

        expect(@purchase.successful?).to be(true)
        expect(@purchase.balance_transactions.count).to eq(1)
        expect(@purchase.balance_transactions.last.user_id).to eq(@affiliate_user.id)
        expect(@purchase.balance_transactions.last.holding_amount_net_cents).to eq(@purchase.affiliate_credit_cents)
      end

      def verify_purchase_refunded
        @purchase.reload
        expect(@purchase.stripe_refunded).to be(true)
        expect(@purchase.refunds.count).to eq(1)
        expect(@purchase.refunds.last.amount_cents).to eq(@purchase.price_cents)
        expect(@purchase.refunds.last.balance_transactions.count).to eq(1)
        expect(@purchase.refunds.last.balance_transactions.last.user_id).to eq(@affiliate_user.id)
        expect(@purchase.refunds.last.balance_transactions.last.holding_amount_net_cents).to(
          eq(-@purchase.affiliate_credit_cents))
      end

      it "refunds the purchase and reverts associated affiliate balance when event type is PAYMENT.CAPTURE.DENIED" do
        @purchase.update!(stripe_transaction_id: "7NW873794T343360M")

        event_info = { "id" => "WH-4SW78779LY2325805-07E03580SX1414828", "create_time" => "2019-02-14T22:20:08.370Z", "resource_type" => "capture", "event_type" => "PAYMENT.CAPTURE.DENIED", "summary" => "A AUD 2.51 AUD capture payment was denied", "resource" => { "amount" => { "currency_code" => "AUD", "value" => "2.51" }, "seller_protection" => { "status" => "ELIGIBLE", "dispute_categories" => ["ITEM_NOT_RECEIVED", "UNAUTHORIZED_TRANSACTION"] }, "update_time" => "2019-02-14T22:20:01Z", "create_time" => "2019-02-14T22:18:14Z", "final_capture" => true, "seller_receivable_breakdown" => { "gross_amount" => { "currency_code" => "AUD", "value" => "2.51" }, "net_amount" => { "currency_code" => "AUD", "value" => "2.51" } }, "links" => [{ "href" => "https://api.paypal.com/v2/payments/captures/7NW873794T343360M", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v2/payments/captures/7NW873794T343360M/refund", "rel" => "refund", "method" => "POST" }, { "href" => "https://api.paypal.com/v2/payments/authorizations/2W543679LP5841156", "rel" => "up", "method" => "GET" }], "id" => "7NW873794T343360M", "status" => "DECLINED" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-4SW78779LY2325805-07E03580SX1414828", "rel" => "self", "method" => "GET", "encType" => "application/json" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-4SW78779LY2325805-07E03580SX1414828/resend", "rel" => "resend", "method" => "POST", "encType" => "application/json" }], "event_version" => "1.0", "resource_version" => "2.0" }

        described_class.handle_order_events(event_info)

        verify_purchase_refunded
      end

      it "refunds the purchase and reverts associated affiliate balance when event type is PAYMENT.CAPTURE.REVERSED" do
        @purchase.update!(stripe_transaction_id: "4L335234718889942")

        event_info = { "id" => "WH-6F207351SC284371F-0KX52201050121307", "create_time" => "2018-08-15T21:30:35.780Z", "resource_type" => "refund", "event_type" => "PAYMENT.CAPTURE.REVERSED", "summary" => "A $ 2.51 USD capture payment was reversed", "resource" => { "seller_payable_breakdown" => { "gross_amount" => { "currency_code" => "USD", "value" => "2.51" }, "paypal_fee" => { "currency_code" => "USD", "value" => "0.00" }, "net_amount" => { "currency_code" => "USD", "value" => "2.51" }, "total_refunded_amount" => { "currency_code" => "GBP", "value" => "7.00" } }, "amount" => { "currency_code" => "USD", "value" => "2.51" }, "update_time" => "2018-08-15T14:30:10-07:00", "create_time" => "2018-08-15T14:30:10-07:00", "links" => [{ "href" => "https://api.paypal.com/v2/payments/refunds/09E71677NS257044M", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v2/payments/captures/4L335234718889942", "rel" => "up", "method" => "GET" }], "id" => "09E71677NS257044M", "note_to_payer" => "Payment reversed", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-6F207351SC284371F-0KX52201050121307", "rel" => "self", "method" => "GET", "encType" => "application/json" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-6F207351SC284371F-0KX52201050121307/resend", "rel" => "resend", "method" => "POST", "encType" => "application/json" }], "event_version" => "1.0", "resource_version" => "2.0" }

        described_class.handle_order_events(event_info)

        verify_purchase_refunded
      end

      it "sets the processor_refund_id and status on the refund record" do
        @purchase.update!(stripe_transaction_id: "0JF852973C016714D")

        event_info = { "id" => "WH-1GE84257G0350133W-6RW800890C634293G", "create_time" => "2018-08-15T19:14:04.543Z", "resource_type" => "refund", "event_type" => "PAYMENT.CAPTURE.REFUNDED", "summary" => "A $ 0.99 USD capture payment was refunded", "resource" => { "seller_payable_breakdown" => { "gross_amount" => { "currency_code" => "USD", "value" => "0.99" }, "paypal_fee" => { "currency_code" => "USD", "value" => "0.02" }, "net_amount" => { "currency_code" => "USD", "value" => "0.97" }, "total_refunded_amount" => { "currency_code" => "USD", "value" => "10.00" } }, "amount" => { "currency_code" => "USD", "value" => "0.99" }, "update_time" => "2018-08-15T12:13:29-07:00", "create_time" => "2018-08-15T12:13:29-07:00", "links" => [{ "href" => "https://api.paypal.com/v2/payments/refunds/1Y107995YT783435V", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v2/payments/captures/0JF852973C016714D", "rel" => "up", "method" => "GET" }], "id" => "1Y107995YT783435V", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G", "rel" => "self", "method" => "GET", "encType" => "application/json" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G/resend", "rel" => "resend", "method" => "POST", "encType" => "application/json" }], "event_version" => "1.0", "resource_version" => "2.0" }

        described_class.handle_order_events(event_info)

        expect(@purchase.refunds.where(processor_refund_id: "1Y107995YT783435V").where(status: "COMPLETED").count).to(
          eq(1))
      end

      it "does not do anything if there is already a refund with same processor_refund_id" do
        @purchase.update!(stripe_transaction_id: "0JF852973C016714D")
        create(:refund, purchase: @purchase, processor_refund_id: "1Y107995YT783435V", amount_cents: 10)
        expect(@purchase.refunds.count).to eq(1)

        event_info = { "id" => "WH-1GE84257G0350133W-6RW800890C634293G", "create_time" => "2018-08-15T19:14:04.543Z", "resource_type" => "refund", "event_type" => "PAYMENT.CAPTURE.REFUNDED", "summary" => "A $ 0.99 USD capture payment was refunded", "resource" => { "seller_payable_breakdown" => { "gross_amount" => { "currency_code" => "USD", "value" => "0.99" }, "paypal_fee" => { "currency_code" => "USD", "value" => "0.02" }, "net_amount" => { "currency_code" => "USD", "value" => "0.97" }, "total_refunded_amount" => { "currency_code" => "USD", "value" => "10.00" } }, "amount" => { "currency_code" => "USD", "value" => "0.99" }, "update_time" => "2018-08-15T12:13:29-07:00", "create_time" => "2018-08-15T12:13:29-07:00", "links" => [{ "href" => "https://api.paypal.com/v2/payments/refunds/1Y107995YT783435V", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v2/payments/captures/0JF852973C016714D", "rel" => "up", "method" => "GET" }], "id" => "1Y107995YT783435V", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G", "rel" => "self", "method" => "GET", "encType" => "application/json" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G/resend", "rel" => "resend", "method" => "POST", "encType" => "application/json" }], "event_version" => "1.0", "resource_version" => "2.0" }

        described_class.handle_order_events(event_info)

        expect(@purchase.refunds.count).to eq(1)
      end

      it "creates refund if there is already a refund associated with the purchase but with different " \
         "processor_refund_id" do
        @purchase.update!(stripe_transaction_id: "0JF852973C016714D")
        create(:refund, purchase: @purchase, processor_refund_id: "refund-id", amount_cents: 10)
        expect(@purchase.refunds.count).to eq(1)

        event_info = { "id" => "WH-1GE84257G0350133W-6RW800890C634293G", "create_time" => "2018-08-15T19:14:04.543Z", "resource_type" => "refund", "event_type" => "PAYMENT.CAPTURE.REFUNDED", "summary" => "A $ 0.99 USD capture payment was refunded", "resource" => { "seller_payable_breakdown" => { "gross_amount" => { "currency_code" => "USD", "value" => "0.99" }, "paypal_fee" => { "currency_code" => "USD", "value" => "0.02" }, "net_amount" => { "currency_code" => "USD", "value" => "0.97" }, "total_refunded_amount" => { "currency_code" => "USD", "value" => "10.00" } }, "amount" => { "currency_code" => "USD", "value" => "0.99" }, "update_time" => "2018-08-15T12:13:29-07:00", "create_time" => "2018-08-15T12:13:29-07:00", "links" => [{ "href" => "https://api.paypal.com/v2/payments/refunds/1Y107995YT783435V", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v2/payments/captures/0JF852973C016714D", "rel" => "up", "method" => "GET" }], "id" => "1Y107995YT783435V", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G", "rel" => "self", "method" => "GET", "encType" => "application/json" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G/resend", "rel" => "resend", "method" => "POST", "encType" => "application/json" }], "event_version" => "1.0", "resource_version" => "2.0" }

        described_class.handle_order_events(event_info)

        expect(@purchase.refunds.where(processor_refund_id: "1Y107995YT783435V").where(status: "COMPLETED").count).to(
          eq(1))
        expect(@purchase.reload.refunds.count).to eq(2)
      end

      it "refunds the purchase and reverts associated affiliate balance when event type is PAYMENT.CAPTURE.REFUNDED" do
        @purchase.update!(stripe_transaction_id: "0JF852973C016714D")

        event_info = { "id" => "WH-1GE84257G0350133W-6RW800890C634293G", "create_time" => "2018-08-15T19:14:04.543Z", "resource_type" => "refund", "event_type" => "PAYMENT.CAPTURE.REFUNDED", "summary" => "A $ 0.99 USD capture payment was refunded", "resource" => { "seller_payable_breakdown" => { "gross_amount" => { "currency_code" => "USD", "value" => "0.99" }, "paypal_fee" => { "currency_code" => "USD", "value" => "0.02" }, "net_amount" => { "currency_code" => "USD", "value" => "0.97" }, "total_refunded_amount" => { "currency_code" => "USD", "value" => "10.00" } }, "amount" => { "currency_code" => "USD", "value" => "0.99" }, "update_time" => "2018-08-15T12:13:29-07:00", "create_time" => "2018-08-15T12:13:29-07:00", "links" => [{ "href" => "https://api.paypal.com/v2/payments/refunds/1Y107995YT783435V", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v2/payments/captures/0JF852973C016714D", "rel" => "up", "method" => "GET" }], "id" => "1Y107995YT783435V", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G", "rel" => "self", "method" => "GET", "encType" => "application/json" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G/resend", "rel" => "resend", "method" => "POST", "encType" => "application/json" }], "event_version" => "1.0", "resource_version" => "2.0" }

        described_class.handle_order_events(event_info)

        verify_purchase_refunded
      end

      it "does nothing if purchase is already fully refunded" do
        @purchase.update!(stripe_transaction_id: "0JF852973C016714D")
        create(:refund, purchase: @purchase, amount_cents: @purchase.price_cents)
        expect(@purchase.refunds.count).to eq(1)

        event_info = { "id" => "WH-1GE84257G0350133W-6RW800890C634293G", "create_time" => "2018-08-15T19:14:04.543Z", "resource_type" => "refund", "event_type" => "PAYMENT.CAPTURE.REFUNDED", "summary" => "A $ 0.99 USD capture payment was refunded", "resource" => { "seller_payable_breakdown" => { "gross_amount" => { "currency_code" => "USD", "value" => "0.99" }, "paypal_fee" => { "currency_code" => "USD", "value" => "0.02" }, "net_amount" => { "currency_code" => "USD", "value" => "0.97" }, "total_refunded_amount" => { "currency_code" => "USD", "value" => "1.98" } }, "amount" => { "currency_code" => "USD", "value" => "0.99" }, "update_time" => "2018-08-15T12:13:29-07:00", "create_time" => "2018-08-15T12:13:29-07:00", "links" => [{ "href" => "https://api.paypal.com/v2/payments/refunds/1Y107995YT783435V", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v2/payments/captures/0JF852973C016714D", "rel" => "up", "method" => "GET" }], "id" => "1Y107995YT783435V", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G", "rel" => "self", "method" => "GET", "encType" => "application/json" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G/resend", "rel" => "resend", "method" => "POST", "encType" => "application/json" }], "event_version" => "1.0", "resource_version" => "2.0" }

        described_class.handle_order_events(event_info)

        expect(@purchase.refunds.count).to eq(1)
      end

      it "refunds remaining amount if purchase is partially refunded" do
        @purchase.update!(stripe_transaction_id: "0JF852973C016714D")
        create(:refund, purchase: @purchase, amount_cents: @purchase.price_cents / 2)
        expect(@purchase.refunds.count).to eq(1)
        expect(@purchase.refunds.last.amount_cents).to eq(@purchase.price_cents / 2)

        event_info = { "id" => "WH-1GE84257G0350133W-6RW800890C634293G", "create_time" => "2018-08-15T19:14:04.543Z", "resource_type" => "refund", "event_type" => "PAYMENT.CAPTURE.REFUNDED", "summary" => "A $ 0.99 USD capture payment was refunded", "resource" => { "seller_payable_breakdown" => { "gross_amount" => { "currency_code" => "USD", "value" => "0.99" }, "paypal_fee" => { "currency_code" => "USD", "value" => "0.02" }, "net_amount" => { "currency_code" => "USD", "value" => "0.97" }, "total_refunded_amount" => { "currency_code" => "USD", "value" => "10.00" } }, "amount" => { "currency_code" => "USD", "value" => "0.99" }, "update_time" => "2018-08-15T12:13:29-07:00", "create_time" => "2018-08-15T12:13:29-07:00", "links" => [{ "href" => "https://api.paypal.com/v2/payments/refunds/1Y107995YT783435V", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v2/payments/captures/0JF852973C016714D", "rel" => "up", "method" => "GET" }], "id" => "1Y107995YT783435V", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G", "rel" => "self", "method" => "GET", "encType" => "application/json" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G/resend", "rel" => "resend", "method" => "POST", "encType" => "application/json" }], "event_version" => "1.0", "resource_version" => "2.0" }

        described_class.handle_order_events(event_info)

        expect(@purchase.refunds.count).to eq(2)
        expect(@purchase.refunds.first.amount_cents).to eq(@purchase.price_cents / 2)
        expect(@purchase.refunds.last.amount_cents).to eq(@purchase.price_cents / 2)
      end

      it "refunds the correct partial amount for partial refunds" do
        @purchase.update!(stripe_transaction_id: "0JF852973C016714D")

        event_info = { "id" => "WH-1GE84257G0350133W-6RW800890C634293G", "create_time" => "2018-08-15T19:14:04.543Z", "resource_type" => "refund", "event_type" => "PAYMENT.CAPTURE.REFUNDED", "summary" => "A $ 0.99 USD capture payment was refunded", "resource" => { "seller_payable_breakdown" => { "gross_amount" => { "currency_code" => "USD", "value" => "0.99" }, "paypal_fee" => { "currency_code" => "USD", "value" => "0.02" }, "net_amount" => { "currency_code" => "USD", "value" => "0.97" }, "total_refunded_amount" => { "currency_code" => "USD", "value" => "1.98" } }, "amount" => { "currency_code" => "USD", "value" => "0.99" }, "update_time" => "2018-08-15T12:13:29-07:00", "create_time" => "2018-08-15T12:13:29-07:00", "links" => [{ "href" => "https://api.paypal.com/v2/payments/refunds/1Y107995YT783435V", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v2/payments/captures/0JF852973C016714D", "rel" => "up", "method" => "GET" }], "id" => "1Y107995YT783435V", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G", "rel" => "self", "method" => "GET", "encType" => "application/json" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G/resend", "rel" => "resend", "method" => "POST", "encType" => "application/json" }], "event_version" => "1.0", "resource_version" => "2.0" }

        described_class.handle_order_events(event_info)

        expect(@purchase.refunds.count).to eq(1)
        expect(@purchase.refunds.last.amount_cents).to eq(198)
      end

      it "refunds the correct amount for single unit currency refunds" do
        @purchase.update!(stripe_transaction_id: "0JF852973C016714D")

        event_info = { "id" => "WH-1GE84257G0350133W-6RW800890C634293G", "create_time" => "2018-08-15T19:14:04.543Z", "resource_type" => "refund", "event_type" => "PAYMENT.CAPTURE.REFUNDED", "summary" => "A 198 JPY capture payment was refunded", "resource" => { "seller_payable_breakdown" => { "gross_amount" => { "currency_code" => "JPY", "value" => "198" }, "paypal_fee" => { "currency_code" => "JPY", "value" => "4" }, "net_amount" => { "currency_code" => "JPY", "value" => "194" }, "total_refunded_amount" => { "currency_code" => "JPY", "value" => "198" } }, "amount" => { "currency_code" => "JPY", "value" => "198" }, "update_time" => "2018-08-15T12:13:29-07:00", "create_time" => "2018-08-15T12:13:29-07:00", "links" => [{ "href" => "https://api.paypal.com/v2/payments/refunds/1Y107995YT783435V", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v2/payments/captures/0JF852973C016714D", "rel" => "up", "method" => "GET" }], "id" => "1Y107995YT783435V", "status" => "COMPLETED" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G", "rel" => "self", "method" => "GET", "encType" => "application/json" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-1GE84257G0350133W-6RW800890C634293G/resend", "rel" => "resend", "method" => "POST", "encType" => "application/json" }], "event_version" => "1.0", "resource_version" => "2.0" }

        described_class.handle_order_events(event_info)

        expect(@purchase.refunds.count).to eq(1)
        expect(@purchase.refunds.last.amount_cents).to eq(253)
      end
    end
  end

  describe "#get_chargeable_for_params" do
    context "when billing agreement id is passed in arguments" do
      let(:params) { { billing_agreement_id: "B-38D505255T217912K" } }
      it "returns object of PaypalChargeable with billing agreement id set as fingerptint" do
        chargeable = PaypalChargeProcessor.new.get_chargeable_for_params(params, nil)
        expect(chargeable.class).to eq(PaypalChargeable)
        expect(chargeable.billing_agreement_id).to eq(params[:billing_agreement_id])
      end
    end

    context "when paypal order id is passed in arguments" do
      let(:params) { { paypal_order_id: "B-38D505255T217912K" } }
      it "returns object of PaypalApprovedOrderChargeable with paypal order id set as fingerptint" do
        chargeable = PaypalChargeProcessor.new.get_chargeable_for_params(params, nil)
        expect(chargeable.class).to eq(PaypalApprovedOrderChargeable)
        expect(chargeable.fingerprint).to eq(params[:paypal_order_id])
      end
    end

    context "when neither billing agreement id nor paypal order id are passed in arguments" do
      it "returns nil" do
        chargeable = PaypalChargeProcessor.new.get_chargeable_for_params({}, nil)
        expect(chargeable).to eq(nil)
      end
    end
  end

  describe "#get_chargeable_for_data" do
    it "returns object of PaypalChargeable with billing agreement id set as fingerptint" do
      chargeable = subject.get_chargeable_for_data("B-38D505255T217912K", nil, "B-38D505255T217912K",
                                                   nil, nil, nil, nil, nil,
                                                   "paypal-gr-integspecs@gumroad.com", nil, nil, CardType::PAYPAL, nil)
      expect(chargeable.class).to eq(PaypalChargeable)
      expect(chargeable.billing_agreement_id).to eq("B-38D505255T217912K")
    end
  end

  describe "#get_charge" do
    context "when purchase is created from order API" do
      let(:purchase_of_order_api) do
        create(:purchase, paypal_order_id: "426572068V1934255",
                          stripe_transaction_id: "58003532R80972514",
                          charge_processor_id: PaypalChargeProcessor.charge_processor_id)
      end
      let(:paypal_order_api_charge) { subject.get_charge(purchase_of_order_api.stripe_transaction_id) }

      it "fetches order and returns paypal charge" do
        expect(PaypalChargeProcessor).to receive(:fetch_order).with(order_id: purchase_of_order_api.paypal_order_id)
                                                              .and_call_original
        expect(paypal_order_api_charge.class).to eq(PaypalCharge)
      end
    end

    context "when purchase is not created from order API" do
      describe "successful transaction" do
        it "retrieves the charge successfully" do
          paypal_charge = subject.get_charge("0MK73950Y39198240")
          expect(paypal_charge).to_not be(nil)
          expect(paypal_charge.refunded).to be(false)
          expect(paypal_charge.card_fingerprint).to eq("paypal_92SVVJSWYT72E")
          expect(paypal_charge.card_country).to eq(Compliance::Countries::USA.alpha2)
        end
      end

      describe "refunded transaction" do
        it "retrieves the charge successfully" do
          paypal_charge = subject.get_charge("5333763431520331H")
          expect(paypal_charge).to_not be(nil)
          expect(paypal_charge.refunded).to be(true)
          expect(paypal_charge.card_fingerprint).to eq("paypal_92SVVJSWYT72E")
          expect(paypal_charge.card_country).to eq(Compliance::Countries::USA.alpha2)
        end
      end

      describe "invalid / non-existant transaction" do
        it "raises an exception" do
          expect do
            subject.get_charge("invalid_charge_id")
          end.to raise_error(ChargeProcessorInvalidRequestError)
        end
      end
    end
  end

  describe "#create_payment_intent_or_charge!" do
    let(:purchase) { create(:purchase) }
    context "when billing_agreement id is present in chargeable" do
      let(:valid_paypal_chargeable) do
        PaypalChargeable.new("B-38D505255T217912K", "paypal-gr-integspecs@gumroad.com", "US")
      end

      it "creates new paypal order and charges it and returns PaypalChargeIntent" do
        expect(PaypalChargeProcessor).to receive(:create_order).and_call_original
        expect_any_instance_of(PaypalChargeProcessor).to receive(:capture_order)
                                                           .with(order_id: an_instance_of(String),
                                                                 billing_agreement_id: "B-38D505255T217912K")
                                                           .and_call_original

        charge_intent = subject.create_payment_intent_or_charge!(
          create(:merchant_account_paypal,
                 user: purchase.seller), valid_paypal_chargeable, 0, 0, purchase.external_id, "")
        expect(charge_intent.class).to eq(PaypalChargeIntent)
      end

      it "does not raise error and returns PaypalCharge when transaction is complete" do
        paypal_auth_token =
          "Bearer A21AAIW-mWqtYFHC_juLm6Ded4UvrZmFdAprGbqIsnyf9Tjay2qdeZqLzZnjGJfNAcQvdNS4Rx0Hgbyu2ukMDARwWHEEBdh1Q"
        allow_any_instance_of(PaypalPartnerRestCredentials).to receive(:auth_token).and_return(paypal_auth_token)

        charge_intent = subject.create_payment_intent_or_charge!(
          create(:merchant_account_paypal, user: purchase.seller, charge_processor_merchant_id: "B66YJBBNCRW6L"),
          valid_paypal_chargeable, 5000, 300, purchase.external_id, "")
        charge = charge_intent.charge

        expect(charge.class).to eq(PaypalCharge)
        expect(charge.paypal_payment_status.downcase).to eq(PaypalApiPaymentStatus::COMPLETED.downcase)
      end

      it "does not raise error and returns PaypalCharge when transaction is pending review" do
        paypal_auth_token =
          "Bearer A21AAIW-mWqtYFHC_juLm6Ded4UvrZmFdAprGbqIsnyf9Tjay2qdeZqLzZnjGJfNAcQvdNS4Rx0Hgbyu2ukMDARwWHEEBdh1Q"
        allow_any_instance_of(PaypalPartnerRestCredentials).to receive(:auth_token).and_return(paypal_auth_token)

        allow(PaypalChargeProcessor).to receive(:create_order).and_return("80T882348N361143U")
        capture_response = JSON.parse(
          { id: "80T882348N361143U", intent: "CAPTURE", status: "COMPLETED",
            purchase_units: [{ reference_id: "JrkmJ574Xk5Nqz1Bv9cLOA==", amount: { currency_code: "USD", value: "29.00", breakdown: { item_total: { currency_code: "USD", value: "29.00" }, shipping: { currency_code: "USD", value: "0.00" }, handling: { currency_code: "USD", value: "0.00" }, tax_total: { currency_code: "USD", value: "0.00" }, insurance: { currency_code: "USD", value: "0.00" }, shipping_discount: { currency_code: "USD", value: "0.00" }, discount: { currency_code: "USD", value: "0.00" } } }, payee: { email_address: "jingsketch@gmail.com", merchant_id: "F8Z2DAMTCQ7R8" }, payment_instruction: { platform_fees: [{ amount: { currency_code: "USD", value: "0.29" }, payee: { email_address: "paypal-api@gumroad.com", merchant_id: "Y9TEHAMRZ4T7L" } }] }, description: "Jingsketch All Access+", items: [{ name: "Jingsketch All Access+", unit_amount: { currency_code: "USD", value: "29.00" }, tax: { currency_code: "USD", value: "0.00" }, quantity: "1", sku: "rnPNZ" }], shipping: { name: { full_name: "Jordan Hager" }, address: {} }, payments: { captures: [{ id: "79740133TG6557546", status: "PENDING", status_details: { reason: "PENDING_REVIEW" }, amount: { currency_code: "USD", value: "29.00" }, final_capture: true, disbursement_mode: "INSTANT", seller_protection: { status: "NOT_ELIGIBLE" }, links: [{ href: "https://api.paypal.com/v2/payments/captures/79740133TG6557546", rel: "self", method: "GET" }, { href: "https://api.paypal.com/v2/payments/captures/79740133TG6557546/refund", rel: "refund", method: "POST" }, { href: "https://api.paypal.com/v2/checkout/orders/80T882348N361143U", rel: "up", method: "GET" }], create_time: "2021-01-04T03:38:43Z", update_time: "2021-01-04T03:38:43Z" }] } }], payer: { name: { given_name: "Jordan", surname: "Hager" }, email_address: "Hirasuni.XBL@gmail.com", payer_id: "6U8QW4SGE3UDQ", phone: { phone_number: { national_number: "5733379177" } }, address: { country_code: "US" } }, update_time: "2021-01-04T03:38:43Z", links: [{ href: "https://api.paypal.com/v2/checkout/orders/80T882348N361143U", rel: "self", method: "GET" }] }.to_json, object_class: OpenStruct)
        allow(PaypalChargeProcessor).to receive(:capture).and_return(capture_response)

        charge_intent = subject.create_payment_intent_or_charge!(
          create(:merchant_account_paypal, user: purchase.seller, charge_processor_merchant_id: "B66YJBBNCRW6L"),
          valid_paypal_chargeable, 5000, 300, purchase.external_id, "")
        charge = charge_intent.charge

        expect(charge.class).to eq(PaypalCharge)
        expect(charge.paypal_payment_status.downcase).to eq(PaypalApiPaymentStatus::PENDING.downcase)
      end

      it "refunds the transaction on paypal and raises error when it is an echeck payment" do
        merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "F8Z2DAMTCQ7R8")

        allow(PaypalChargeProcessor).to receive(:create_order).and_return("80T882348N361143U")
        capture_response = JSON.parse(
          { id: "80T882348N361143U", intent: "CAPTURE", status: "COMPLETED",
            purchase_units: [{ reference_id: "JrkmJ574Xk5Nqz1Bv9cLOA==", amount: { currency_code: "USD", value: "29.00", breakdown: { item_total: { currency_code: "USD", value: "29.00" }, shipping: { currency_code: "USD", value: "0.00" }, handling: { currency_code: "USD", value: "0.00" }, tax_total: { currency_code: "USD", value: "0.00" }, insurance: { currency_code: "USD", value: "0.00" }, shipping_discount: { currency_code: "USD", value: "0.00" }, discount: { currency_code: "USD", value: "0.00" } } }, payee: { email_address: "jingsketch@gmail.com", merchant_id: "F8Z2DAMTCQ7R8" }, payment_instruction: { platform_fees: [{ amount: { currency_code: "USD", value: "0.29" }, payee: { email_address: "paypal-api@gumroad.com", merchant_id: "Y9TEHAMRZ4T7L" } }] }, description: "Jingsketch All Access+", items: [{ name: "Jingsketch All Access+", unit_amount: { currency_code: "USD", value: "29.00" }, tax: { currency_code: "USD", value: "0.00" }, quantity: "1", sku: "rnPNZ" }], shipping: { name: { full_name: "Jordan Hager" }, address: {} }, payments: { captures: [{ id: "79740133TG6557546", status: "PENDING", status_details: { reason: "ECHECK" }, amount: { currency_code: "USD", value: "29.00" }, final_capture: true, disbursement_mode: "INSTANT", seller_protection: { status: "NOT_ELIGIBLE" }, links: [{ href: "https://api.paypal.com/v2/payments/captures/79740133TG6557546", rel: "self", method: "GET" }, { href: "https://api.paypal.com/v2/payments/captures/79740133TG6557546/refund", rel: "refund", method: "POST" }, { href: "https://api.paypal.com/v2/checkout/orders/80T882348N361143U", rel: "up", method: "GET" }], create_time: "2021-01-04T03:38:43Z", update_time: "2021-01-04T03:38:43Z" }] } }], payer: { name: { given_name: "Jordan", surname: "Hager" }, email_address: "Hirasuni.XBL@gmail.com", payer_id: "6U8QW4SGE3UDQ", phone: { phone_number: { national_number: "5733379177" } }, address: { country_code: "US" } }, update_time: "2021-01-04T03:38:43Z", links: [{ href: "https://api.paypal.com/v2/checkout/orders/80T882348N361143U", rel: "self", method: "GET" }] }.to_json, object_class: OpenStruct)
        allow(PaypalChargeProcessor).to receive(:capture).and_return(capture_response)

        expect(subject).to receive(:refund!).with("79740133TG6557546", merchant_account:,
                                                                       paypal_order_purchase_unit_refund: true)
        expect do
          subject.create_payment_intent_or_charge!(
            create(:merchant_account_paypal, user: purchase.seller, charge_processor_merchant_id: "F8Z2DAMTCQ7R8"),
            valid_paypal_chargeable, 5000, 300, purchase.external_id, "")
        end.to raise_error(ChargeProcessorCardError)
      end
    end

    context "when paypal order id is present in chargeable" do
      it "charges already approved order without creating a new order and returns PaypalCharge" do
        purchase = create(:purchase, paypal_order_id: "5AF67588T4374172W")
        chargeable = PaypalApprovedOrderChargeable.new(purchase.paypal_order_id, "paypal-gr-integspecs@gumroad.com",
                                                       "US")

        expect_any_instance_of(PaypalChargeProcessor).not_to receive(:create_order)
        expect_any_instance_of(PaypalChargeProcessor).to receive(:update_invoice_id).and_call_original
        expect_any_instance_of(PaypalChargeProcessor).to receive(:capture_order)
                                                           .with(order_id: purchase.paypal_order_id).and_call_original

        charge = subject.create_payment_intent_or_charge!(create(:merchant_account_paypal, user: purchase.seller),
                                                          chargeable, 0, 0, purchase.external_id, "")

        expect(charge.class).to eq(PaypalChargeIntent)
      end
    end

    context "when billing agreement id is not present in chargeable" do
      let(:invalid_paypal_chargeable) { PaypalChargeable.new(nil, nil, nil) }

      it "raises error" do
        expect do
          subject.create_payment_intent_or_charge!(create(:merchant_account_paypal, user: purchase.seller),
                                                   invalid_paypal_chargeable, 0, 0, purchase.external_id, "")
        end.to raise_error(ChargeProcessorInvalidRequestError)
      end
    end


    context "when one combined charge is created for multiple purchases" do
      before do
        seller = create(:user)
        merchant_account = create(:merchant_account_paypal, user: seller, charge_processor_merchant_id: "B66YJBBNCRW6L")
        @charge = create(:charge, seller:, merchant_account:)
        @charge.purchases << create(:purchase)
        @charge.purchases << create(:purchase)
        paypal_auth_token =
          "Bearer A21AAIwPw4niCFO4ziUTNt46mLva8lrt4cmMackDZFvFNVqEIpkEMzh6z-tt5cb2Sw6YcPsT1kVfuBdsVkAnZcAx9XFiMiGIw"
        allow_any_instance_of(PaypalPartnerRestCredentials).to receive(:auth_token).and_return(paypal_auth_token)
      end

      context "when billing_agreement id is present in chargeable" do
        let(:valid_paypal_chargeable) do
          PaypalChargeable.new("B-38D505255T217912K", "paypal-gr-integspecs@gumroad.com", "US")
        end

        it "creates new paypal order and charges it and returns PaypalChargeIntent" do
          expect(PaypalChargeProcessor).to receive(:paypal_order_info_from_charge).and_call_original
          expect(PaypalChargeProcessor).to receive(:create_order_from_charge).and_call_original
          expect_any_instance_of(PaypalChargeProcessor).to receive(:capture_order)
                                                             .with(order_id: an_instance_of(String),
                                                                   billing_agreement_id: "B-38D505255T217912K")
                                                             .and_call_original

          charge_intent = subject.create_payment_intent_or_charge!(@charge.merchant_account, valid_paypal_chargeable,
                                                                   10_00, 1_00, "CH-#{@charge.external_id}", "")
          paypal_charge = charge_intent.charge
          expect(charge_intent.class).to eq(PaypalChargeIntent)
          expect(paypal_charge.class).to eq(PaypalCharge)
          expect(paypal_charge.paypal_payment_status.downcase).to eq(PaypalApiPaymentStatus::COMPLETED.downcase)
        end
      end

      context "when billing agreement id is not present in chargeable" do
        let(:invalid_paypal_chargeable) { PaypalChargeable.new(nil, nil, nil) }

        it "raises error" do
          expect do
            subject.create_payment_intent_or_charge!(@charge.merchant_account, invalid_paypal_chargeable,
                                                     10_00, 1_00, "CH-#{@charge.external_id}", "")
          end.to raise_error(ChargeProcessorInvalidRequestError)
        end
      end
    end
  end

  describe "#refund!" do
    let(:merchant_account) { create(:merchant_account_paypal) }
    context "when refund is for order api" do
      context "when it is a partial refund" do
        let(:partial_refund_response) do
          subject.refund!("3R951669WT495394B",
                          amount_cents: 200,
                          merchant_account:,
                          paypal_order_purchase_unit_refund: true)
        end

        it "refunds the specified amount" do
          expect_any_instance_of(PaypalRestApi).to receive(:refund).with(capture_id: "3R951669WT495394B",
                                                                         merchant_account:, amount: 2.0)
                                                                   .and_call_original
          expect(partial_refund_response.class).to eq(PaypalOrderRefund)
          expect(partial_refund_response.charge_id).to eq("3R951669WT495394B")
        end

        context "when invalid capture id is passed" do
          it "raises ChargeProcessorInvalidRequestError error" do
            expect do
              subject.refund!("invalid_capture_id",
                              amount_cents: 200,
                              merchant_account:,
                              paypal_order_purchase_unit_refund: true)
            end.to raise_error(ChargeProcessorInvalidRequestError)
          end
        end

        context "when purchase unit is already refunded" do
          it "raises ChargeProcessorInvalidRequestError error" do
            error_pattern = /The capture has already been fully refunded/
            expect do
              subject.refund!("1F993023VT0037447",
                              amount_cents: 200,
                              merchant_account:,
                              paypal_order_purchase_unit_refund: true)
            end.to raise_error(ChargeProcessorAlreadyRefundedError).with_message(error_pattern)
          end
        end

        context "when refund amount is greater than the remaining amount" do
          it "raises ChargeProcessorInvalidRequestError error" do
            error_pattern =
              /The refund amount must be less than or equal to the capture amount that has not yet been refunded/
            expect do
              subject.refund!("3R951669WT495394B",
                              amount_cents: 10_000,
                              merchant_account:,
                              paypal_order_purchase_unit_refund: true)
            end.to raise_error(ChargeProcessorInvalidRequestError).with_message(error_pattern)
          end
        end
      end

      context "when it is a full refund" do
        it "refunds entire amount" do
          expect_any_instance_of(PaypalRestApi).to receive(:refund).with(capture_id: "2CL11631PW424125C",
                                                                         merchant_account:, amount: 0.0)
                                                                   .and_call_original

          full_refund_response = subject.refund!("2CL11631PW424125C", paypal_order_purchase_unit_refund: true,
                                                                      merchant_account:)

          expect(full_refund_response.class).to eq(PaypalOrderRefund)
          expect(full_refund_response.charge_id).to eq("2CL11631PW424125C")
        end

        it "refunds entire amount if currency is not usd" do
          merchant_account = create(:merchant_account_paypal, currency: "gbp",
                                                              charge_processor_merchant_id: "MV9KWAJWMZ722")
          expect_any_instance_of(PaypalRestApi).to receive(:refund).with(capture_id: "9XP40559459729230",
                                                                         merchant_account:, amount: 0.0)
                                                                   .and_call_original

          full_refund_response = subject.refund!("9XP40559459729230", paypal_order_purchase_unit_refund: true,
                                                                      merchant_account:)

          expect(full_refund_response.class).to eq(PaypalOrderRefund)
          expect(full_refund_response.charge_id).to eq("9XP40559459729230")
        end

        context "when invalid capture id is passed" do
          it "raises ChargeProcessorInvalidRequestError error" do
            expect do
              subject.refund!("invalid_capture_id", paypal_order_purchase_unit_refund: true, merchant_account:)
            end.to raise_error(ChargeProcessorInvalidRequestError)
          end
        end

        context "when purchase unit is already refunded" do
          it "raises ChargeProcessorAlreadyRefundedError error" do
            expect do
              subject.refund!("2CL11631PW424125C", paypal_order_purchase_unit_refund: true, merchant_account:)
            end.to raise_error(ChargeProcessorAlreadyRefundedError).
              with_message(/The capture has already been fully refunded/)
          end
        end
      end

      it "raises ChargeProcessorUnavailableError when refund API is not working" do
        allow_any_instance_of(PaypalRestApi).to receive(:refund).and_raise(ChargeProcessorUnavailableError)
        expect do
          subject.refund!("2CL11631PW424125C", paypal_order_purchase_unit_refund: true, merchant_account:)
        end.to raise_error(ChargeProcessorUnavailableError)
      end
    end
  end

  describe ".create_order" do
    let(:link) { create(:product) }
    let(:purchase) do
      create(:purchase, link:, shipping_cents: 0, price_cents: 500, tax_cents: 0, quantity: 1)
    end

    before do
      allow_any_instance_of(PaypalRestApi).to receive(:timestamp).and_return("1574057788")
      create(:merchant_account_paypal, user: purchase.seller)
    end

    context "when valid inputs are passed" do
      before do
        @response = PaypalChargeProcessor.create_order(PaypalChargeProcessor.paypal_order_info(purchase))
      end

      it "returns order_id" do
        expect(@response).to_not be(nil)
      end
    end

    context "when invalid inputs are passed" do
      it "raises proper error" do
        purchase.quantity = 0
        expect do
          PaypalChargeProcessor.create_order(PaypalChargeProcessor.paypal_order_info(purchase))
        end.to raise_error(ZeroDivisionError)
      end

      it "notifies Bugsnag" do
        expect(Bugsnag).to receive(:notify).exactly(:once)
        begin
          PaypalChargeProcessor.create_order(nil)
        rescue StandardError
          nil
        end
      end

      context "when `purchase` is empty" do
        it "notifies Bugsnag and raises the exception" do
          expect(Bugsnag).to receive(:notify).exactly(:once)
          expect { PaypalChargeProcessor.create_order(nil) }.to raise_error(ChargeProcessorError)
        end
      end
    end
  end

  describe ".capture" do
    context "when valid order_id is passed" do
      let(:capture_order_response) do
        PaypalChargeProcessor.capture(order_id: "0T022567XC990424P", billing_agreement_id: nil)
      end

      it "returns a valid order id" do
        expect(capture_order_response.id).to eq("0T022567XC990424P")
      end
    end

    context "when invalid order_id is passed" do
      it "raises ChargeProcessorError error" do
        expect do
          PaypalChargeProcessor.capture(order_id: "invalid_order_id", billing_agreement_id: nil)
        end.to raise_error(ChargeProcessorError)
      end
    end

    it "raises ChargeProcessorPayerCancelledBillingAgreementError error if paypal returns billing agreement cancelled" \
       " error" do
      error_response = JSON.parse({ result: {
        name: "UNPROCESSABLE_ENTITY",
        details: [issue: "AGREEMENT_ALREADY_CANCELLED",
                  description: "The requested agreement is already canceled."] } }.to_json, object_class: OpenStruct)

      allow_any_instance_of(PaypalRestApi).to receive(:capture).and_return(error_response)

      expect do
        PaypalChargeProcessor.capture(order_id: "0T022567XC990424P", billing_agreement_id: "B-38D505255T217912K")
      end.to raise_error(ChargeProcessorPayerCancelledBillingAgreementError)
    end

    it "raises ChargeProcessorUnavailableError error if paypal returns internal error" do
      error_response = JSON.parse({ result: {
        name: "INTERNAL_ERROR",
        details: [issue: "INTERNAL_ERROR"] } }.to_json, object_class: OpenStruct)

      allow_any_instance_of(PaypalRestApi).to receive(:capture).and_return(error_response)

      expect do
        PaypalChargeProcessor.capture(order_id: "0T022567XC990424P", billing_agreement_id: "B-38D505255T217912K")
      end.to raise_error(ChargeProcessorUnavailableError)
    end

    it "raises ChargeProcessorPaymentDeclinedByPayerAccountError error if paypal returns transaction declined error" do
      error_response = JSON.parse({ result: {
        name: "UNPROCESSABLE_ENTITY",
        details: [issue: "TRANSACTION_REFUSED"] } }.to_json, object_class: OpenStruct)

      allow_any_instance_of(PaypalRestApi).to receive(:capture).and_return(error_response)

      expect do
        PaypalChargeProcessor.capture(order_id: "0T022567XC990424P", billing_agreement_id: "B-38D505255T217912K")
      end.to raise_error(ChargeProcessorPaymentDeclinedByPayerAccountError)
    end

    it "raises ChargeProcessorPayeeAccountRestrictedError error if paypal returns problem with payee account" do
      error_response = JSON.parse({ result: {
        name: "UNPROCESSABLE_ENTITY",
        details: [issue: "PAYEE_ACCOUNT_RESTRICTED"] } }.to_json, object_class: OpenStruct)

      allow_any_instance_of(PaypalRestApi).to receive(:capture).and_return(error_response)

      expect do
        PaypalChargeProcessor.capture(order_id: "0T022567XC990424P", billing_agreement_id: "B-38D505255T217912K")
      end.to raise_error(ChargeProcessorPayeeAccountRestrictedError)
    end

    it "raises ChargeProcessorPaymentDeclinedByPayerAccountError error if paypal returns a problem stating the payer " \
       "cannot pay" do
      error_response = JSON.parse({ result: {
        name: "UNPROCESSABLE_ENTITY",
        details: [issue: "PAYER_CANNOT_PAY"] } }.to_json, object_class: OpenStruct)

      allow_any_instance_of(PaypalRestApi).to receive(:capture).and_return(error_response)

      expect do
        PaypalChargeProcessor.capture(order_id: "0T022567XC990424P", billing_agreement_id: "B-38D505255T217912K")
      end.to raise_error(ChargeProcessorPaymentDeclinedByPayerAccountError)
    end
  end

  describe ".fetch_order" do
    context "when valid order_id is passed" do
      let(:fetch_order_response) { PaypalChargeProcessor.fetch_order(order_id: "0T022567XC990424P") }

      it "returns order information" do
        expect(fetch_order_response["id"]).to eq("0T022567XC990424P")
        expect(fetch_order_response["status"]).to eq("COMPLETED")
        expect(fetch_order_response["purchase_units"].size).to eq(1)
        expect(fetch_order_response["purchase_units"][0]["amount"]["value"]).to eq("5.00")
      end
    end

    context "when invalid order_id is passed" do
      it "raises ChargeProcessorError error" do
        expect { PaypalChargeProcessor.fetch_order(order_id: "invalid_order_id") }.to raise_error(ChargeProcessorError)
      end
    end
  end

  describe ".log_paypal_api_response" do
    it "logs the response in a format we desire" do
      api_response = OpenStruct.new(headers: { "server" => ["Apache"], "content-length" => ["708"] },
                                    parsed_response: { "success" => "true", "resource_id" => "100" })

      expect(Rails.logger).to receive(:info).with("Some API (123) headers => #{api_response.headers.inspect}")
      expect(Rails.logger).to receive(:info).with("Some API (123) body => #{api_response.inspect}")

      PaypalChargeProcessor.log_paypal_api_response("Some API", 123, api_response)
    end
  end

  describe ".paypal_order_info" do
    before do
      @creator = create(:user)
      product_name = "🚧 MDE.TV High-Roller Paywall 🚧 (INCLUDES ALL NEW 🍖 VIDEO CONTENT & NICK ROCHEFORT) and you " \
                     "also get......... 💥 THE GREAT WAR!!! 💥 Your Favourite!!!"
      @product = create(:product, user: @creator, name: product_name)
      paypal_merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                                 user: @creator, country: "GB", currency: "gbp")
      @purchase = create(:purchase, link: @product, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                    merchant_account: paypal_merchant_account, price_cents: 11_00,
                                    gumroad_tax_cents: 2_00, shipping_cents: 1_50, fee_cents: 60,
                                    total_transaction_cents: 13_00, quantity: 2)
    end

    it "returns the info required to create paypal order for a given purchase" do
      paypal_order_info = {
        invoice_id: @purchase.external_id,
        product_permalink: @purchase.link.unique_permalink,
        item_name: "MDE.TV HighRoller Paywall  INCLUDES ALL NEW  VIDEO CONTENT  NICK ROCHEFORT and you also " \
                   "get.........  THE GREAT WAR  Your Favou",
        currency: @purchase.merchant_account.currency,
        merchant_id: @purchase.merchant_account.charge_processor_merchant_id,
        quantity: @purchase.quantity,
        descriptor: @purchase.statement_description,
        price: PaypalChargeProcessor.format_money(@purchase.price_cents - @purchase.shipping_cents,
                                                  @purchase.merchant_account.currency),
        shipping: PaypalChargeProcessor.format_money(@purchase.shipping_cents, @purchase.merchant_account.currency),
        tax: PaypalChargeProcessor.format_money(@purchase.gumroad_tax_cents, @purchase.merchant_account.currency),
        fee: PaypalChargeProcessor.format_money(@purchase.fee_cents + @purchase.gumroad_tax_cents,
                                                @purchase.merchant_account.currency),
        total: PaypalChargeProcessor.format_money(@purchase.price_cents - @purchase.shipping_cents,
                                                  @purchase.merchant_account.currency) +
               PaypalChargeProcessor.format_money(@purchase.shipping_cents,
                                                  @purchase.merchant_account.currency) +
               PaypalChargeProcessor.format_money(@purchase.gumroad_tax_cents,
                                                  @purchase.merchant_account.currency),
        unit_price:
          PaypalChargeProcessor.format_money((@purchase.price_cents - @purchase.shipping_cents) / @purchase.quantity,
                                             @purchase.merchant_account.currency)
      }
      expect(PaypalChargeProcessor.paypal_order_info(@purchase)).to eq(paypal_order_info)
    end

    it "sets the item name as product's custom_permalink if product's name becomes empty on sanitization" do
      @product.name = "🚧 🚧 🍖 💥 💥"
      @product.custom_permalink = "custom"
      @product.save!

      paypal_order_info = {
        invoice_id: @purchase.external_id,
        product_permalink: @purchase.link.unique_permalink,
        item_name: "custom",
        currency: @purchase.merchant_account.currency,
        merchant_id: @purchase.merchant_account.charge_processor_merchant_id,
        quantity: @purchase.quantity,
        descriptor: @purchase.statement_description,
        price: PaypalChargeProcessor.format_money(@purchase.price_cents - @purchase.shipping_cents,
                                                  @purchase.merchant_account.currency),
        shipping: PaypalChargeProcessor.format_money(@purchase.shipping_cents, @purchase.merchant_account.currency),
        tax: PaypalChargeProcessor.format_money(@purchase.gumroad_tax_cents, @purchase.merchant_account.currency),
        fee: PaypalChargeProcessor.format_money(@purchase.fee_cents + @purchase.gumroad_tax_cents,
                                                @purchase.merchant_account.currency),
        total: PaypalChargeProcessor.format_money(@purchase.price_cents - @purchase.shipping_cents,
                                                  @purchase.merchant_account.currency) +
               PaypalChargeProcessor.format_money(@purchase.shipping_cents,
                                                  @purchase.merchant_account.currency) +
               PaypalChargeProcessor.format_money(@purchase.gumroad_tax_cents,
                                                  @purchase.merchant_account.currency),
        unit_price:
          PaypalChargeProcessor.format_money((@purchase.price_cents - @purchase.shipping_cents) / @purchase.quantity,
                                             @purchase.merchant_account.currency)
      }

      expect(PaypalChargeProcessor.paypal_order_info(@purchase)).to eq(paypal_order_info)
    end

    it "sets the item name as product's unique_permalink if the product's name becomes empty on sanitization and " \
       "there's no custom_permalink" do
      @product.name = "🚧 🚧 🍖 💥 💥"
      @product.save!

      paypal_order_info = {
        invoice_id: @purchase.external_id,
        product_permalink: @purchase.link.unique_permalink,
        item_name: @product.unique_permalink,
        currency: @purchase.merchant_account.currency,
        merchant_id: @purchase.merchant_account.charge_processor_merchant_id,
        quantity: @purchase.quantity,
        descriptor: @purchase.statement_description,
        price: PaypalChargeProcessor.format_money(@purchase.price_cents - @purchase.shipping_cents,
                                                  @purchase.merchant_account.currency),
        shipping: PaypalChargeProcessor.format_money(@purchase.shipping_cents, @purchase.merchant_account.currency),
        tax: PaypalChargeProcessor.format_money(@purchase.gumroad_tax_cents, @purchase.merchant_account.currency),
        fee: PaypalChargeProcessor.format_money(@purchase.fee_cents + @purchase.gumroad_tax_cents,
                                                @purchase.merchant_account.currency),
        total: PaypalChargeProcessor.format_money(@purchase.price_cents - @purchase.shipping_cents,
                                                  @purchase.merchant_account.currency) +
               PaypalChargeProcessor.format_money(@purchase.shipping_cents,
                                                  @purchase.merchant_account.currency) +
               PaypalChargeProcessor.format_money(@purchase.gumroad_tax_cents,
                                                  @purchase.merchant_account.currency),
        unit_price:
          PaypalChargeProcessor.format_money((@purchase.price_cents - @purchase.shipping_cents) / @purchase.quantity,
                                             @purchase.merchant_account.currency)
      }

      expect(PaypalChargeProcessor.paypal_order_info(@purchase)).to eq(paypal_order_info)
    end
  end

  describe ".create_order_from_purchase" do
    it "creates a new paypal order for the purchase" do
      creator = create(:user)
      product = create(:product, user: creator)
      paypal_merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                                 user: creator, country: "GB", currency: "gbp")
      purchase = create(:purchase, link: product, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                   merchant_account: paypal_merchant_account, price_cents: 10_00,
                                   gumroad_tax_cents: 2_00, shipping_cents: 1_50, fee_cents: 60,
                                   total_transaction_cents: 12_00, quantity: 3)

      paypal_order_id = PaypalChargeProcessor.create_order_from_purchase(purchase)
      expect(paypal_order_id).to be_present
    end
  end

  describe ".create_order_from_product_info" do
    it "creates a new paypal order with the given product info" do
      creator = create(:user)
      product = create(:product, user: creator)
      paypal_merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                                 user: creator, country: "GB", currency: "gbp")

      purchase_unit_info = {
        external_id: product.external_id,
        currency_code: paypal_merchant_account.currency,
        price_cents: 10_00,
        shipping_cents: 1_50,
        tax_cents: 2_00,
        exclusive_tax_cents: 2_00,
        total_cents: 13_50,
        quantity: 2,
      }

      paypal_order_id = PaypalChargeProcessor.create_order_from_product_info(purchase_unit_info)
      expect(paypal_order_id).to be_present
    end

    it "creates a new paypal order if product currency is usd but merchant account currency is not" do
      creator = create(:user)
      product_name = "🚧 MDE.TV High-Roller Paywall 🚧 (INCLUDES ALL NEW 🍖 VIDEO CONTENT & NICK ROCHEFORT) " \
                     "and you also get......... 💥 THE GREAT WAR!!! 💥 Your Favourite!!!"
      product = create(:product, user: creator, name: product_name)
      paypal_merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                                 user: creator, country: "GB", currency: "gbp")

      purchase_unit_info = {
        external_id: product.external_id,
        currency_code: "usd",
        price_cents: 15_00,
        shipping_cents: 1_50,
        tax_cents: 2_00,
        exclusive_tax_cents: 2_00,
        total_cents: 18_50,
        quantity: 2,
      }

      expected_args = { permalink: product.unique_permalink,
                        item_name: product_name.gsub(
                          /[^A-Z0-9. ]/i, "").to_s.strip[0...PaypalChargeProcessor::MAXIMUM_ITEM_NAME_LENGTH],
                        currency: "gbp",
                        merchant_id: paypal_merchant_account.charge_processor_merchant_id,
                        descriptor: product.statement_description.gsub(/[^A-Z0-9. ]/i, "").to_s,
                        price_cents_usd: 15_00,
                        shipping_cents_usd: 1_50,
                        tax_cents_usd: 2_00,
                        fee_cents_usd: 150,
                        total_cents_usd: 18_50,
                        quantity: 2 }

      expect(PaypalChargeProcessor).to receive(:create_purchase_unit_info).with(**expected_args).and_call_original
      paypal_order_id = PaypalChargeProcessor.create_order_from_product_info(purchase_unit_info)
      expect(paypal_order_id).to be_present
    end

    it "creates a new paypal order if merchant account currency is usd but product currency is not" do
      creator = create(:user)
      product = create(:product, user: creator, price_currency_type: "aud")
      paypal_merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "B66YJBBNCRW6L",
                                                                 user: creator, country: "US", currency: "usd")

      purchase_unit_info = {
        external_id: product.external_id,
        currency_code: "aud",
        price_cents: 15_00,
        shipping_cents: 1_50,
        tax_cents: 2_00,
        exclusive_tax_cents: 2_00,
        total_cents: 18_50,
        quantity: 2,
      }

      expected_args = { permalink: product.unique_permalink,
                        item_name: product.name,
                        currency: "usd",
                        merchant_id: paypal_merchant_account.charge_processor_merchant_id,
                        descriptor: product.statement_description.gsub(/[^A-Z0-9. ]/i, "").to_s,
                        price_cents_usd: 15_47,
                        shipping_cents_usd: 1_55,
                        tax_cents_usd: 2_06,
                        fee_cents_usd: 154,
                        total_cents_usd: 19_08,
                        quantity: 2 }

      expect(PaypalChargeProcessor).to receive(:create_purchase_unit_info).with(**expected_args).and_call_original
      paypal_order_id = PaypalChargeProcessor.create_order_from_product_info(purchase_unit_info)
      expect(paypal_order_id).to be_present
    end

    it "creates a new paypal order if merchant account currency and product currency are different and none is usd" do
      creator = create(:user)
      product = create(:product, user: creator, price_currency_type: "aud")
      paypal_merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                                 user: creator, country: "GB", currency: "gbp")

      purchase_unit_info = {
        external_id: product.external_id,
        currency_code: "aud",
        price_cents: 15_00,
        shipping_cents: 1_50,
        tax_cents: 2_00,
        exclusive_tax_cents: 2_00,
        total_cents: 18_50,
        quantity: 2,
      }

      expected_args = { permalink: product.unique_permalink,
                        item_name: product.name,
                        currency: "gbp",
                        merchant_id: paypal_merchant_account.charge_processor_merchant_id,
                        descriptor: product.statement_description.gsub(/[^A-Z0-9. ]/i, "").to_s,
                        price_cents_usd: 15_47,
                        shipping_cents_usd: 1_55,
                        tax_cents_usd: 2_06,
                        fee_cents_usd: 154,
                        total_cents_usd: 19_08,
                        quantity: 2 }

      expect(PaypalChargeProcessor).to receive(:create_purchase_unit_info).with(**expected_args).and_call_original
      paypal_order_id = PaypalChargeProcessor.create_order_from_product_info(purchase_unit_info)
      expect(paypal_order_id).to be_present
    end


    it "creates a new paypal order with item name as product's custom_permalink if product's name becomes empty on " \
       "sanitization" do
      creator = create(:user)
      product = create(:product, user: creator, price_currency_type: "aud", name: "🚧 🚧 🍖 💥 💥",
                                 custom_permalink: "custom")
      paypal_merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                                 user: creator, country: "GB", currency: "gbp")

      purchase_unit_info = {
        external_id: product.external_id,
        currency_code: "aud",
        price_cents: 15_00,
        shipping_cents: 1_50,
        tax_cents: 2_00,
        exclusive_tax_cents: 2_00,
        total_cents: 18_50,
        quantity: 2,
      }

      expected_args = { permalink: product.unique_permalink,
                        item_name: "custom",
                        currency: "gbp",
                        merchant_id: paypal_merchant_account.charge_processor_merchant_id,
                        descriptor: product.statement_description.gsub(/[^A-Z0-9. ]/i, "").to_s,
                        price_cents_usd: 15_47,
                        shipping_cents_usd: 1_55,
                        tax_cents_usd: 2_06,
                        fee_cents_usd: 154,
                        total_cents_usd: 19_08,
                        quantity: 2 }

      expect(PaypalChargeProcessor).to receive(:create_purchase_unit_info).with(**expected_args).and_call_original

      paypal_order_id = PaypalChargeProcessor.create_order_from_product_info(purchase_unit_info)
      expect(paypal_order_id).to be_present
    end

    it "creates a new paypal order with item name as product's unique_permalink if the product's name becomes empty " \
       "on sanitization and there's no custom_permalink" do
      creator = create(:user)
      product = create(:product, user: creator, price_currency_type: "aud", name: "🚧 🚧 🍖 💥 💥")
      paypal_merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                                 user: creator, country: "GB", currency: "gbp")

      purchase_unit_info = {
        external_id: product.external_id,
        currency_code: "aud",
        price_cents: 15_00,
        shipping_cents: 1_50,
        tax_cents: 2_00,
        exclusive_tax_cents: 2_00,
        total_cents: 18_50,
        quantity: 2,
      }

      expect(PaypalChargeProcessor).to receive(:create_purchase_unit_info).with(
        { permalink: product.unique_permalink,
          item_name: product.unique_permalink,
          currency: "gbp",
          merchant_id: paypal_merchant_account.charge_processor_merchant_id,
          descriptor: product.statement_description.gsub(
            /[^A-Z0-9. ]/i, "").to_s,
          price_cents_usd: 15_47,
          shipping_cents_usd: 1_55,
          tax_cents_usd: 2_06,
          fee_cents_usd: 154,
          total_cents_usd: 19_08,
          quantity: 2 }).and_call_original

      paypal_order_id = PaypalChargeProcessor.create_order_from_product_info(purchase_unit_info)
      expect(paypal_order_id).to be_present
    end
  end

  describe ".update_order_from_product_info" do
    it "updates the paypal order with the given product info and returns true" do
      creator = create(:user)
      product = create(:product, user: creator)
      paypal_merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "MN7CSWD6RCNJ8",
                                                                 user: creator, country: "US", currency: "usd")

      purchase_unit_info = {
        external_id: product.external_id,
        currency_code: paypal_merchant_account.currency,
        price_cents: 10_00,
        shipping_cents: 1_50,
        tax_cents: 2_00,
        exclusive_tax_cents: 2_00,
        total_cents: 13_50,
        quantity: 2,
      }

      paypal_order_id = PaypalChargeProcessor.create_order_from_product_info(purchase_unit_info)
      expect(paypal_order_id).to be_present

      order_details = PaypalChargeProcessor.fetch_order(order_id: paypal_order_id)
      purchase_unit = order_details["purchase_units"][0]
      expect(purchase_unit["amount"]["value"]).to eq("13.50")
      expect(purchase_unit["amount"]["breakdown"]["item_total"]["value"]).to eq("10.00")
      expect(purchase_unit["amount"]["breakdown"]["shipping"]["value"]).to eq("1.50")
      expect(purchase_unit["amount"]["breakdown"]["tax_total"]["value"]).to eq("2.00")
      expect(purchase_unit["payee"]["merchant_id"]).to eq("MN7CSWD6RCNJ8")
      expect(purchase_unit["items"][0]["quantity"]).to eq("2")
      expect(purchase_unit["items"][0]["unit_amount"]["value"]).to eq("5.00")
      expect(purchase_unit["payment_instruction"]["platform_fees"].size).to eq(1)
      expect(purchase_unit["payment_instruction"]["platform_fees"][0]["amount"]["value"]).to eq("0.70")

      updated_purchase_unit_info = {
        external_id: product.external_id,
        currency_code: paypal_merchant_account.currency,
        price_cents: 5_00,
        shipping_cents: 75,
        tax_cents: 1_00,
        exclusive_tax_cents: 1_00,
        total_cents: 6_75,
        quantity: 2,
      }

      expect(PaypalChargeProcessor).to receive(:update_order).and_call_original
      success = PaypalChargeProcessor.update_order_from_product_info(paypal_order_id, updated_purchase_unit_info)
      expect(success).to be (true)

      order_details = PaypalChargeProcessor.fetch_order(order_id: paypal_order_id)
      purchase_unit = order_details["purchase_units"][0]
      expect(purchase_unit["amount"]["value"]).to eq("6.75")
      expect(purchase_unit["amount"]["breakdown"]["item_total"]["value"]).to eq("5.00")
      expect(purchase_unit["amount"]["breakdown"]["shipping"]["value"]).to eq("0.75")
      expect(purchase_unit["amount"]["breakdown"]["tax_total"]["value"]).to eq("1.00")
      expect(purchase_unit["payee"]["email_address"]).to eq("sb-c7jpx2385730@business.example.com")
      expect(purchase_unit["items"][0]["quantity"]).to eq("2")
      expect(purchase_unit["items"][0]["unit_amount"]["value"]).to eq("2.50")
      expect(purchase_unit["payment_instruction"]["platform_fees"].size).to eq(1)
      expect(purchase_unit["payment_instruction"]["platform_fees"][0]["amount"]["value"]).to eq("0.35")
    end

    it "raises error if paypal order id is not present" do
      updated_purchase_unit_info = {
        external_id: "JrkmJ574Xk5Nqz1Bv9cLOA==",
        currency_code: "usd",
        price_cents: 5_00,
        shipping_cents: 75,
        tax_cents: 1_00,
        exclusive_tax_cents: 1_00,
        total_cents: 6_75,
        quantity: 2,
      }

      expect do
        PaypalChargeProcessor.update_order_from_product_info("", updated_purchase_unit_info)
      end.to raise_error(ChargeProcessorError)
    end

    it "raises error if product info is not present" do
      expect do
        PaypalChargeProcessor.update_order_from_product_info("27B71908FM8616631", {})
      end.to raise_error(ChargeProcessorError)
    end
  end

  describe "#update_invoice_id" do
    it "updates the invoice id for paypal order" do
      creator = create(:user)
      product = create(:product, user: creator)
      paypal_merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                                 user: creator, country: "GB", currency: "gbp")

      purchase_unit_info = {
        external_id: product.external_id,
        currency_code: paypal_merchant_account.currency,
        price_cents: 10_00,
        shipping_cents: 1_50,
        tax_cents: 2_00,
        exclusive_tax_cents: 2_00,
        total_cents: 13_50,
        quantity: 2,
      }

      paypal_order_id = PaypalChargeProcessor.create_order_from_product_info(purchase_unit_info)
      expect(paypal_order_id).to be_present

      paypal_order = PaypalChargeProcessor.fetch_order(order_id: paypal_order_id)
      expect(paypal_order["id"]).to eq(paypal_order_id)
      expect(paypal_order["invoice_id"]).to be(nil)

      PaypalChargeProcessor.new.update_invoice_id(order_id: paypal_order_id, invoice_id: "updated-invoice-id")

      paypal_order = PaypalChargeProcessor.fetch_order(order_id: paypal_order_id)
      expect(paypal_order["id"]).to eq(paypal_order_id)
      expect(paypal_order["purchase_units"][0]["invoice_id"]).to eq("updated-invoice-id")
    end

    it "raises ChargeProcessorUnavailableError error if paypal api call fails with INTERNAL_ERROR" do
      error_response = JSON.parse({ result: { name: "INTERNAL_ERROR" } }.to_json, object_class: OpenStruct)

      expect_any_instance_of(PaypalRestApi).to receive(:update_invoice_id).and_return(error_response)

      expect { subject.update_invoice_id(order_id: 1, invoice_id: 1) }.to raise_error(ChargeProcessorUnavailableError)
    end

    it "raises ChargeProcessorInvalidRequestError error if paypal api call fails with any other error than " \
       "INTERNAL_ERROR" do
      error_response = JSON.parse({ result: { name: "UNPROCESSABLE_ENTITY" } }.to_json, object_class: OpenStruct)

      expect_any_instance_of(PaypalRestApi).to receive(:update_invoice_id).and_return(error_response)

      expect do
        subject.update_invoice_id(order_id: 1, invoice_id: 1)
      end.to raise_error(ChargeProcessorInvalidRequestError)
    end
  end

  describe "#get_charge_for_order_api" do
    let(:paypal_order_id) { "35R447743K110460F" }

    it "returns a PayPal charge object with details of the given paypal capture id and order id" do
      charge = subject.send(:get_charge_for_order_api, "0PU60443CD7008232", paypal_order_id)

      expect(charge).to be_a(PaypalCharge)
      expect(charge.id).to eq("0PU60443CD7008232")
      expect(charge.status).to eq("completed")
    end

    it "returns a PayPal charge object with details of the paypal capture even if only the order id is provided" do
      charge = subject.send(:get_charge_for_order_api, nil, paypal_order_id)

      expect(charge).to be_a(PaypalCharge)
      expect(charge.id).to eq("0PU60443CD7008232")
      expect(charge.status).to eq("completed")
    end
  end

  describe "#search_charge" do
    let(:purchase) { create(:purchase, paypal_order_id: "35R447743K110460F") }

    it "returns a PayPal charge object with details of the paypal order attached to the given purchase" do
      charge = subject.search_charge(purchase:)

      expect(charge).to be_a(PaypalCharge)
      expect(charge.id).to eq("0PU60443CD7008232")
      expect(charge.status).to eq("completed")
    end

    it "returns nil if no paypal order is found for the given purchase" do
      expect(subject.search_charge(purchase: create(:purchase))).to be(nil)
    end
  end

  describe ".formatted_amount_for_paypal" do
    it "returns decimal values for currencies other than TWD, HUF, and JPY" do
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "usd")).to eq(16.44) # unit to subunit is 100
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "usd").class).to eq(BigDecimal)
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "gbp")).to eq(16.44) # unit to subunit is 100
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "gbp").class).to eq(BigDecimal)
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "inr")).to eq(16.44) # unit to subunit is 100
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "inr").class).to eq(BigDecimal)
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "clp")).to eq(1644.0) # unit to subunit is 1
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "clp").class).to eq(BigDecimal)
    end

    it "returns integer values for TWD, HUF, and JPY currencies" do
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "twd")).to eq(16) # unit to subunit is 100
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "twd").class).to eq(Integer)
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "huf")).to eq(16) # unit to subunit is 100
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "huf").class).to eq(Integer)
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "jpy")).to eq(1644) # unit to subunit is 1
      expect(PaypalChargeProcessor.formatted_amount_for_paypal(1644, "jpy").class).to eq(Integer)
    end
  end
end
