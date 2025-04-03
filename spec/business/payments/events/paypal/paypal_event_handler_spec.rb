# frozen_string_literal: true

describe PaypalEventHandler do
  describe "#schedule_paypal_event_processing" do
    context "when event is from paypal orders API" do
      PaypalEventType::ORDER_API_EVENTS.each do |event_type|
        before do
          @event_info = { "event_type" => event_type }
        end

        it do
          described_class.new(@event_info).schedule_paypal_event_processing
          expect(HandlePaypalEventWorker).to have_enqueued_sidekiq_job(@event_info)
        end
      end
    end

    context "when event is from Integrated signup API" do
      PaypalEventType::MERCHANT_ACCOUNT_EVENTS.each do |event_type|
        before do
          @event_info = { "event_type" => event_type }

          it do
            described_class.new(@event_info).schedule_paypal_event_processing
            expect(HandlePaypalEventWorker).to have_enqueued_sidekiq_job(@event_info)
          end
        end
      end
    end

    context "when event is from paypal legacy API" do
      let(:event_info) { { "txn_type" => "masspay" } }

      it do
        described_class.new(event_info).schedule_paypal_event_processing
        expect(HandlePaypalEventWorker).to have_enqueued_sidekiq_job(event_info).in(10.minutes)
      end
    end
  end

  describe "#handle_paypal_event" do
    context "when event is from Integrated signup API" do
      it do
        event_info = { "event_type" => PaypalEventType::MERCHANT_PARTNER_CONSENT_REVOKED }
        expect_any_instance_of(PaypalMerchantAccountManager).to receive(:handle_paypal_event).with(event_info)
        described_class.new(event_info).handle_paypal_event
      end
    end

    context "when event is from paypal legacy API" do
      context "and IPN verification succeeds" do
        before do
          WebMock.stub_request(:post, "https://ipnpb.sandbox.paypal.com/cgi-bin/webscr").to_return(body: "VERIFIED")
        end

        describe "paypal events mocked from production" do
          describe "pay via paypal and handle IPNs" do
            describe "reversal and cancelled reversal IPN messages" do
              describe "reversal event" do
                before do
                  raw_payload =
                      "payment_type=echeck&payment_date=Sun%20May%2024%202015%2014%3A32%3A31%20GMT-0700%20%28PDT%29&payment_status=Reversed&" \
                  "payer_status=verified&first_name=John&last_name=Smith&payer_email=buyer%40paypalsandbox.com&payer_id=TESTBUYERID01&address_name=John%20Smith&address_country=United%20States&" \
                  "address_country_code=US&address_zip=95131&address_state=CA&address_city=San%20Jose&address_street=123%20any%20street&business=seller%40paypalsandbox.com&" \
                  "receiver_email=seller%40paypalsandbox.com&receiver_id=seller%40paypalsandbox.com&residence_country=US&item_name=something&item_number=AK-1234&quantity=1&" \
                  "shipping=3.04&tax=2.02&mc_currency=USD&mc_fee=0.44&mc_gross=12.34&mc_gross1=12.34&txn_type=web_accept&txn_id=995288809&notify_version=2.1&parent_txn_id=SOMEPRIORTXNID002&" \
                  "reason_code=chargeback&receipt_ID=3012-5109-3782-6103&custom=xyz123&invoice=dPFcxp0U0xmL5o0TD1NP9g%3D%3D&test_ipn=1&" \
                  "verify_sign=AFcWxV21C7fd0v3bYYYRCpSSRl31A4SYxlXZ9IdB.iATdIIByT4aW.Qa"

                  @payload = Rack::Utils.parse_nested_query(raw_payload)
                end

                it "handles a chargeback message from PayPal" do
                  expect(PaypalPayoutProcessor).to_not receive(:handle_paypal_event)
                  expect(PaypalChargeProcessor).to receive(:handle_paypal_event).and_call_original

                  described_class.new(@payload).handle_paypal_event
                end
              end

              describe "reversal cancelled event" do
                before do
                  raw_payload =
                      "payment_type=instant&payment_date=Sun%20May%2024%202015%2015%3A04%3A11%20GMT-0700%20%28PDT%29&payment_status=Canceled_Reversal&" \
                  "address_status=confirmed&payer_status=verified&first_name=John&last_name=Smith&payer_email=buyer%40paypalsandbox.com&payer_id=TESTBUYERID01&" \
                  "address_name=John%20Smith&address_country=United%20States&address_country_code=US&address_zip=95131&address_state=CA&address_city=San%20Jose&" \
                  "address_street=123%20any%20street&business=seller%40paypalsandbox.com&receiver_email=seller%40paypalsandbox.com&receiver_id=seller%40paypalsandbox.com&residence_country=US&" \
                  "item_name=something&item_number=AK-1234&quantity=1&shipping=3.04&tax=2.02&mc_currency=USD&mc_fee=0.44&mc_gross=12.34&mc_gross1=12.34&txn_type=web_accept&txn_id=694541630&" \
                  "notify_version=2.1&parent_txn_id=SOMEPRIORTXNID003&reason_code=other&custom=xyz123&invoice=D7lNKK8L-urz8D3awchsUA%3D%3D&test_ipn=1&" \
                  "verify_sign=AFcWxV21C7fd0v3bYYYRCpSSRl31A48M..jE7GasP8rDsyMNp6bZuihz"

                  @payload = Rack::Utils.parse_nested_query(raw_payload)
                end

                it "handles a chargeback reversed message from PayPal" do
                  expect(PaypalPayoutProcessor).to_not receive(:handle_paypal_event)
                  expect(PaypalChargeProcessor).to receive(:handle_paypal_event)

                  described_class.new(@payload).handle_paypal_event
                end
              end
            end
          end

          describe "purchase event with an invoice field", :vcr do
            before do
              raw_payload =
                  "payment_type=instant&payment_date=Tue%20May%2026%202015%2017%3A15%3A44%20GMT-0700%20%28PDT%29&payment_status=Completed&address_status=confirmed&payer_status=verified&" \
              "first_name=John&last_name=Smith&payer_email=buyer%40paypalsandbox.com&payer_id=TESTBUYERID01&address_name=John%20Smith&address_country=United%20States&address_country_code=US&" \
              "address_zip=95131&address_state=CA&address_city=San%20Jose&address_street=123%20any%20street&business=seller%40paypalsandbox.com&receiver_email=seller%40paypalsandbox.com&" \
              "receiver_id=seller%40paypalsandbox.com&residence_country=US&item_name1=something&item_number1=AK-1234&tax=2.02&mc_currency=USD&mc_fee=0.44&mc_gross=12.34&mc_gross1=12.34&" \
              "mc_handling=2.06&mc_handling1=1.67&mc_shipping=3.02&mc_shipping1=1.02&txn_type=cart&txn_id=108864103&notify_version=2.1&custom=xyz123&invoice=random_external_id%3D%3D&" \
              "test_ipn=1&verify_sign=ACAZ6FVFxLgizH8UbrtwxaIa4AOcAwq2HjoeG6XjAhqWvKP.pgZUJAqk"

              @payload = Rack::Utils.parse_nested_query(raw_payload)
            end

            it "is handled by the PayPal charge processor" do
              expect(PaypalChargeProcessor).to receive(:handle_paypal_event).and_call_original
              expect(PaypalPayoutProcessor).to_not receive(:handle_paypal_event)

              described_class.new(@payload).handle_paypal_event
            end
          end

          describe "payouts IPN messages" do
            before do
              raw_payload =
                  "txn_type=masspay&payment_gross_1=10.00&payment_date=17:19:05 Jun 24, 2015 PDT&last_name=Lavingia&mc_fee_1=0.20&masspay_txn_id_1=8G377690596809442&" \
              "receiver_email_1=paypal-buyer@gumroad.com&residence_country=US&verify_sign=Ae-XDUZhrxwaCSsmGO9JpO33K7P1AozUnt1w.tzHJKWOWYlez5cVvscv&payer_status=verified&" \
              "test_ipn=1&payer_email=paypal-gr-sandbox@gumroad.com&first_name=Sahil&payment_fee_1=0.20&payer_id=3FBN6YS9YFTV6&payer_business_name=Sahil Lavingia's Test Store&" \
              "payment_status=Processed&status_1=Completed&mc_gross_1=10.00&charset=windows-1252&notify_version=3.8&mc_currency_1=USD&unique_id_1=38&ipn_track_id=29339dfb40e24"

              @payload = Rack::Utils.parse_nested_query(raw_payload)
              @payment = create(:payment, id: 38)
            end

            it "assigns messages with the masspay transaction type to the payout processor" do
              expect(@payment.state).to eq("processing")
              expect(PaypalPayoutProcessor).to receive(:handle_paypal_event).with(@payload).and_call_original

              described_class.new(@payload).handle_paypal_event

              expect(@payment.reload.state).to eq("completed")
            end
          end
        end

        describe "ignored IPN messages" do
          describe "cart checkout IPN messages" do
            before do
              raw_payload =
                  "payment_date=17:36:04 Jul 22, 2015 PDT&txn_type=cart&last_name=buyer&residence_country=US&pending_reason=order&item_name=Gumroad Purchase& " \
            "payment_gross=127.56&mc_currency=USD&verify_sign=AUkau1FwogE3kL3qo1vGTARqlijQAi30ARWjcqXEBUjAiWyIw2fh8BbU&payer_status=verified&test_ipn=1&tax=0.00&" \
            "payer_email=paypal-buyer@gumroad.com&txn_id=O-1WA78012KV456861R&quantity=1&receiver_email=paypal-gr-sandbox@gumroad.com&first_name=test&payer_id=YZGRBNEN5T2QJ&"\
            "receiver_id=3FBN6YS9YFTV6&item_number=&payer_business_name=Gumroad Inc.&handling_amount=0.00&payment_status=Pending&shipping=0.00&mc_gross=127.56&custom=&" \
            "transaction_entity=order&charset=windows-1252&notify_version=3.8&ipn_track_id=afd7f243d4729"

              @payload = Rack::Utils.parse_nested_query(raw_payload)
            end

            it "does nothing with express checkout messages for Order creation and does not error out" do
              expect(Payment).to_not receive(:find)
              expect(Purchase).to_not receive(:find_by_external_id)
              expect(Bugsnag).to_not receive(:notify)

              described_class.new(@payload).handle_paypal_event
            end
          end

          describe "express checkout IPN messages", :vcr do
            before do
              raw_payload =
                  "payment_date=17:36:04 Jul 22, 2015 PDT&txn_type=express_checkout&last_name=buyer&residence_country=US&pending_reason=order&item_name=Gumroad Purchase& " \
              "payment_gross=127.56&mc_currency=USD&verify_sign=AUkau1FwogE3kL3qo1vGTARqlijQAi30ARWjcqXEBUjAiWyIw2fh8BbU&payer_status=verified&test_ipn=1&tax=0.00&" \
              "payer_email=paypal-buyer@gumroad.com&txn_id=O-1WA78012KV456861R&quantity=1&receiver_email=paypal-gr-sandbox@gumroad.com&first_name=test&payer_id=YZGRBNEN5T2QJ&"\
              "receiver_id=3FBN6YS9YFTV6&item_number=&payer_business_name=Gumroad Inc.&handling_amount=0.00&payment_status=Pending&shipping=0.00&mc_gross=127.56&custom=&" \
              "transaction_entity=order&charset=windows-1252&notify_version=3.8&ipn_track_id=afd7f243d4729"

              @payload = Rack::Utils.parse_nested_query(raw_payload)
            end

            it "does nothing with express checkout messages for Order creation and does not error out" do
              expect(Payment).to_not receive(:find)
              expect(Purchase).to_not receive(:find_by_external_id)
              expect(Bugsnag).to_not receive(:notify)

              described_class.new(@payload).handle_paypal_event
            end
          end

          describe "express checkout IPN message with invalid IPN", :vcr do
            before do
              raw_payload =
                  "payment_date=17:36:04 Jul 22, 2015 PDT&txn_type=express_checkout&last_name=buyer&residence_country=US&pending_reason=order&item_name=Gumroad Purchase& " \
            "payment_gross=127.56&mc_currency=USD&verify_sign=AUkau1FwogE3kL3qo1vGTARqlijQAi30ARWjcqXEBUjAiWyIw2fh8BbU&payer_status=verified&test_ipn=1&tax=0.00&" \
            "payer_email=paypal-buyer@gumroad.com&txn_id=xxxxxx-1WA78012KV456861R&quantity=1&receiver_email=paypal-gr-sandbox@gumroad.com&first_name=test&payer_id=YZGRBNEN5T2QJ&"\
            "receiver_id=3FBN6YS9YFTV6&item_number=&payer_business_name=Gumroad Inc.&handling_amount=0.00&payment_status=Pending&shipping=0.00&mc_gross=127.56&custom=&" \
            "transaction_entity=order&charset=windows-1252&notify_version=3.8&ipn_track_id=afd7f243d4729"

              @payload = Rack::Utils.parse_nested_query(raw_payload)
            end

            it "does nothing with invalid transaction ipn" do
              expect(Payment).to_not receive(:find)
              expect(Purchase).to_not receive(:find_by_external_id)
              expect(Bugsnag).to_not receive(:notify)

              described_class.new(@payload).handle_paypal_event
            end
          end

          describe "Billing agreement creation checkout messages" do
            before do
              raw_payload =
                  "payment_date=17:36:04 Jul 22, 2015 PDT&txn_type=mp_signup&last_name=buyer&residence_country=US&pending_reason=order&item_name=Gumroad Purchase& " \
              "payment_gross=127.56&mc_currency=USD&verify_sign=AUkau1FwogE3kL3qo1vGTARqlijQAi30ARWjcqXEBUjAiWyIw2fh8BbU&payer_status=verified&test_ipn=1&tax=0.00&" \
              "payer_email=paypal-buyer@gumroad.com&txn_id=O-1WA78012KV456861R&quantity=1&receiver_email=paypal-gr-sandbox@gumroad.com&first_name=test&payer_id=YZGRBNEN5T2QJ&"\
              "receiver_id=3FBN6YS9YFTV6&item_number=&payer_business_name=Gumroad Inc.&handling_amount=0.00&payment_status=Pending&shipping=0.00&mc_gross=127.56&custom=&" \
              "transaction_entity=order&charset=windows-1252&notify_version=3.8&ipn_track_id=afd7f243d4729"

              @payload = Rack::Utils.parse_nested_query(raw_payload)
            end

            it "does nothing with express checkout messages for new billing agreeement and does not error out" do
              expect(Payment).to_not receive(:find)
              expect(Purchase).to_not receive(:find_by_external_id)
              expect(Bugsnag).to_not receive(:notify)

              described_class.new(@payload).handle_paypal_event
            end
          end
        end
      end

      context "and IPN verification fails" do
        before do
          WebMock.stub_request(:post, "https://ipnpb.sandbox.paypal.com/cgi-bin/webscr").to_return(body: "INVALID")
        end

        it "does not process the IPN payload" do
          payment = create(:payment)

          raw_payload =
            "txn_type=masspay&payment_gross_1=10.00&payment_date=17:19:05 Jun 24, 2015 PDT&last_name=Lavingia&mc_fee_1=0.20&masspay_txn_id_1=8G377690596809442&" \
            "receiver_email_1=paypal-buyer@gumroad.com&residence_country=US&verify_sign=Ae-XDUZhrxwaCSsmGO9JpO33K7P1AozUnt1w.tzHJKWOWYlez5cVvscv&payer_status=verified&" \
            "test_ipn=1&payer_email=paypal-gr-sandbox@gumroad.com&first_name=Sahil&payment_fee_1=0.20&payer_id=3FBN6YS9YFTV6&payer_business_name=Sahil Lavingia's Test Store&" \
            "payment_status=Processed&status_1=Completed&mc_gross_1=10.00&charset=windows-1252&notify_version=3.8&mc_currency_1=USD&unique_id_1=#{payment.id}&ipn_track_id=29339dfb40e24"
          payload = Rack::Utils.parse_nested_query(raw_payload)

          expect(PaypalPayoutProcessor).not_to receive(:handle_paypal_event)

          described_class.new(payload).handle_paypal_event

          expect(payment.state).to eq("processing")
        end
      end
    end
  end
end
