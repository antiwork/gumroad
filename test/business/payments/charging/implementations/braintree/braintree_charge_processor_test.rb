# frozen_string_literal: true

require "test_helper"

class BraintreeChargeProcessorTest < ActiveSupport::TestCase
  self.described_class = BraintreeChargeProcessor
  self.rspec_metadata = { vcr: true }



  context_ BraintreeChargeProcessor, :vcr do
  context_ ".charge_processor_id" do
  test "returns 'stripe'" do
        expect(BraintreeChargeProcessor.charge_processor_id).to eq "braintree"
      end
    end

    let(:braintree_chargeable) do
      chargeable = BraintreeChargeableNonce.new(Braintree::Test::Nonce::PayPalFuturePayment, nil)
      chargeable.prepare!
      Chargeable.new([chargeable])
    end

  context_ "#get_chargeable_for_params" do
  context_ "with invalid params" do
  test "returns nil" do
          expect(subject.get_chargeable_for_params({}, nil)).to be(nil)
        end
      end

  context_ "with only nonce" do
        let(:paypal_nonce) { Braintree::Test::Nonce::PayPalFuturePayment }

  test "returns a chargeable nonce" do
          expect(BraintreeChargeableNonce).to receive(:new).with(paypal_nonce, nil).and_call_original

          expect(subject.get_chargeable_for_params({ braintree_nonce: paypal_nonce }, nil)).to be_a(BraintreeChargeableNonce)
        end
      end

  context_ "with transient customer key", :vcr do
        before do
          @frozen_time = Time.current
          travel_to(@frozen_time) do
            @braintree_transient_customer_store_key = "braintree_transient_customer_store_key"
            BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer(Braintree::Test::Nonce::PayPalFuturePayment, @braintree_transient_customer_store_key)
          end
        end

  test "returns a transient customer" do
          travel_to(@frozen_time) do
            expect(subject.get_chargeable_for_params({ braintree_transient_customer_store_key: @braintree_transient_customer_store_key }, nil)).to be_a(BraintreeChargeableTransientCustomer)
          end
        end
      end

  context_ "with braintree device data for fraud check on braintree's side" do
        let(:dummy_device_data) { { dummy_session_id: "dummy" }.to_json }

  context_ "with a braintree nonce" do
          let(:paypal_nonce) { Braintree::Test::Nonce::PayPalFuturePayment }

  test "returns a chargeable nonce with the device data JSON string set" do
            expect(BraintreeChargeableNonce).to receive(:new).with(paypal_nonce, nil).and_call_original
            actual_chargeable = subject.get_chargeable_for_params({ braintree_nonce: paypal_nonce,
                                                                    braintree_device_data: dummy_device_data }, nil)
            expect(actual_chargeable).to be_a(BraintreeChargeableNonce)
            expect(actual_chargeable.braintree_device_data).to eq(dummy_device_data)
          end
        end

  context_ "with a transient customer store key with the device data JSON string set" do
          before do
            @frozen_time = Time.current
            travel_to(@frozen_time) do
              @braintree_transient_customer_store_key = "braintree_transient_customer_store_key"
              BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer(Braintree::Test::Nonce::PayPalFuturePayment, @braintree_transient_customer_store_key)
            end
          end

  test "returns a transient customer" do
            travel_to(@frozen_time) do
              actual_chargeable = subject.get_chargeable_for_params({ braintree_transient_customer_store_key: @braintree_transient_customer_store_key,
                                                                      braintree_device_data: dummy_device_data }, nil)
              expect(actual_chargeable).to be_a(BraintreeChargeableTransientCustomer)
              expect(actual_chargeable.braintree_device_data).to eq(dummy_device_data)
            end
          end
        end
      end
    end

  context_ "#get_chargeable_for_data" do
  context_ "with customer id as retreivable token" do
  test "returns a credit card with the reusable token set" do
          expect(BraintreeChargeableCreditCard).to receive(:new)
                                                       .with(braintree_chargeable.reusable_token_for!(BraintreeChargeProcessor.charge_processor_id, nil), nil, nil, nil, nil, nil, nil, nil, nil, nil)
                                                       .and_call_original

          expect(subject.get_chargeable_for_data(braintree_chargeable.reusable_token_for!(BraintreeChargeProcessor.charge_processor_id, nil), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil))
              .to be_a(BraintreeChargeableCreditCard)
        end
      end
    end

  context_ "#get_charge" do
      let(:braintree_charge_txn) do
        params = {
          merchant_account_id: BRAINTREE_MERCHANT_ACCOUNT_ID_FOR_SUPPLIERS,
          amount: 100_00 / 100.0,
          customer_id: braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id).reusable_token!(nil),
          options: {
            submit_for_settlement: true
          }
        }
        Braintree::Transaction.sale!(params)
      end

  context_ "with an invalid charge id" do
  test "throws a charge processor invalid exception" do
          expect do
            subject.get_charge("invalid")
          end.to raise_error(ChargeProcessorInvalidRequestError)
        end
      end

  context_ "with a valid charge id" do
  test "retrieves and returns a braintree charge object" do
          actual_charge = subject.get_charge(braintree_charge_txn.id)

          expect(actual_charge).not_to be(nil)
          expect(actual_charge).to be_a(BraintreeCharge)
          expect(actual_charge.charge_processor_id).to eq(BraintreeChargeProcessor.charge_processor_id)
          expect(actual_charge.zip_check_result).to be(nil)
          expect(actual_charge.id).to eq(braintree_charge_txn.id)
          expect(actual_charge.fee).to be(nil)
          expect(actual_charge.card_fingerprint).to eq("paypal_jane.doe@example.com")
        end
      end

  context_ "when the charge processor is unavailable" do
        before do
          expect(Braintree::Transaction).to receive(:find).and_raise(Braintree::ServiceUnavailableError)
        end

  test "raises an error" do
          expect { subject.get_charge("a-charge-id") }.to raise_error(ChargeProcessorUnavailableError)
        end
      end
    end

  context_ "#search_charge" do
  test "returns a Braintree::Transaction object with details of the transaction attached to the given purchase" do
        allow_any_instance_of(Purchase).to receive(:external_id).and_return("50WuYB5aQYhDx2gzaxhP-Q==")

        charge = subject.search_charge(purchase: create(:purchase, charge_processor_id: BraintreeChargeProcessor.charge_processor_id))

        expect(charge).to be_a(Braintree::Transaction)
        expect(charge.id).to eq("f4ajns4e")
        expect(charge.status).to eq("settled")
      end

  test "returns nil if no transaction is found for the given purchase" do
        allow_any_instance_of(Purchase).to receive(:external_id).and_return(ObfuscateIds.encrypt(1234567890))

        expect(subject.search_charge(purchase: create(:purchase, charge_processor_id: BraintreeChargeProcessor.charge_processor_id))).to be(nil)
      end
    end

  context_ "#create_payment_intent_or_charge!" do
      let(:braintree_merchant_account) { MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id) }

  context_ "successful charging" do
  test "charges the card and returns a braintree charge" do
          actual_charge = subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                                   braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                                   225_00,
                                                                   0,
                                                                   "product-id",
                                                                   nil,
                                                                   statement_description: "dummy").charge

          expect(actual_charge).not_to be(nil)
          expect(actual_charge).to be_a(BraintreeCharge)

          expect(actual_charge.charge_processor_id).to eq("braintree")
          expect(actual_charge.id).not_to be(nil)

          actual_txn = Braintree::Transaction.find(actual_charge.id)
          expect(actual_txn).not_to be(nil)
          expect(actual_txn.amount).to eq(225.0)
          expect(actual_txn.customer_details.id).to eq(braintree_chargeable.reusable_token_for!(BraintreeChargeProcessor.charge_processor_id, nil))
        end
      end

  context_ "successful charging with device data passed to braintree" do
        let(:dummy_device_data) do
          { device_session_id: "174dbf8146df0e205f9e04e54000bc11",
            fraud_merchant_id: "600000",
            correlation_id: "e69e3cd5129668146948413a77988f26" }.to_json
        end

        let(:braintree_chargeable) do
          chargeable = BraintreeChargeableNonce.new(Braintree::Test::Nonce::PayPalFuturePayment, nil)
          chargeable.braintree_device_data = dummy_device_data
          chargeable.prepare!
          Chargeable.new([chargeable])
        end

  test "charges the card and returns a braintree charge" do
          expect(Braintree::Transaction)
              .to receive(:sale)
                      .with(hash_including(device_data: dummy_device_data, options: { submit_for_settlement: true, paypal: { description: "sample description" } }))
                      .and_call_original
          actual_charge = subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                                   braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                                   225_00,
                                                                   0,
                                                                   "product-id",
                                                                   "sample description",
                                                                   statement_description: "dummy").charge

          expect(actual_charge).not_to be(nil)
          expect(actual_charge).to be_a(BraintreeCharge)

          expect(actual_charge.charge_processor_id).to eq("braintree")
          expect(actual_charge.id).not_to be(nil)

          actual_txn = Braintree::Transaction.find(actual_charge.id)
          expect(actual_txn).not_to be(nil)
          expect(actual_txn.amount).to eq(225.0)
          expect(actual_txn.customer_details.id).to eq(braintree_chargeable.reusable_token_for!(BraintreeChargeProcessor.charge_processor_id, nil))
        end
      end

  context_ "unsuccessful charging" do
  context_ "when the charge processor is unavailable" do
          before do
            expect(Braintree::Transaction).to receive(:sale).and_raise(Braintree::ServiceUnavailableError)
          end

  test "raises an error" do
            expect do
              subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                       braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                       225_00,
                                                       0,
                                                       "product-id",
                                                       nil,
                                                       statement_description: "dummy")
            end.to raise_error(ChargeProcessorUnavailableError)
          end
        end

        # Braintree echo'es back the charge amount as the error code for testing.
        # We use this feature to simulate various failure responses.
        # See https://developers.braintreepayments.com/javascript+ruby/reference/general/processor-responses/authorization-responses

  context_ "failures emulated by payment amount" do
  context_ "when card is declined" do
  test "returns an error" do
              expect do
                subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                         braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                         204_600,
                                                         0,
                                                         "product-id",
                                                         nil,
                                                         statement_description: "dummy")
              end.to raise_error do |error|
                expect(error).to be_a(ChargeProcessorCardError)
                expect(error.error_code).to eq("2046")
                expect(error.message).to eq("Declined")
              end
            end
          end

  context_ "when paypal account is unsupported" do
  test "returns an error" do
              expect do
                subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                         braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                         207_100,
                                                         0,
                                                         "product-id",
                                                         nil,
                                                         statement_description: "dummy")
              end.to raise_error(ChargeProcessorUnsupportedPaymentAccountError)
            end
          end

  context_ "when paypal payment instrument is unsupported" do
  test "returns an error" do
              expect do
                subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                         braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                         207_400,
                                                         0,
                                                         "product-id",
                                                         nil,
                                                         statement_description: "dummy")
              end.to raise_error(ChargeProcessorUnsupportedPaymentTypeError)
            end
          end

  context_ "when paypal payment instrument is unsupported" do
  test "returns an error" do
              expect do
                subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                         braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                         207_400,
                                                         0,
                                                         "product-id",
                                                         nil,
                                                         statement_description: "dummy")
              end.to raise_error(ChargeProcessorUnsupportedPaymentTypeError)
            end
          end

  context_ "when paypal payment instrument is unsupported" do
  test "returns an error" do
              expect do
                subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                         braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                         207_400,
                                                         0,
                                                         "product-id",
                                                         nil,
                                                         statement_description: "dummy")
              end.to raise_error(ChargeProcessorUnsupportedPaymentTypeError)
            end
          end

  context_ "when paypal payment is settlement declined" do
  test "returns an error" do
              expect do
                subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                         braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                         400_100,
                                                         0,
                                                         "product-id",
                                                         nil,
                                                         statement_description: "dummy")
              end.to raise_error do |error|
                expect(error).to be_a(ChargeProcessorCardError)
                expect(error.error_code).to eq("4001")
                expect(error.message).to eq("Settlement Declined")
              end
            end
          end
        end
      end
    end

  context_ "#refund!" do
      let(:braintree_merchant_account) { MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id) }

  context_ "when the charge processor is unavailable" do
        before do
          expect(Braintree::Transaction).to receive(:refund!).and_raise(Braintree::ServiceUnavailableError)
        end

  test "raises an error" do
          expect { subject.refund!("dummy") }.to raise_error(ChargeProcessorUnavailableError)
        end
      end

  context_ "refunding an non-existant transaction" do
  test "raises an error" do
          expect do
            subject.refund!("invalid-charge-id")
          end.to raise_error(ChargeProcessorInvalidRequestError)
        end
      end

  context_ "fully refunding a charge" do
        before do
          @charge = subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                             braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                             225_00,
                                                             0,
                                                             "product-id",
                                                             nil,
                                                             statement_description: "dummy").charge
        end

  context_ "fully refunding a charge is successful" do
  test "returns a BraintreeChargeRefund object" do
            expect(subject.refund!(@charge.id)).to be_a(BraintreeChargeRefund)
          end

  test "returns the refund id" do
            expect(subject.refund!(@charge.id).id).to match(/^[a-z0-9]+$/)
          end

  test "returns the charge id" do
            expect(subject.refund!(@charge.id).charge_id).to eq(@charge.id)
          end
        end

  context_ "refunding an already fully refunded charge" do
          before do
            subject.refund!(@charge.id)
          end

  test "raises an error" do
            expect do
              subject.refund!(@charge.id)
            end.to raise_error(ChargeProcessorAlreadyRefundedError)
          end
        end

  context_ "refunding an already chargedback charge, which will return a ValidationFailed without errors specified" do
          before do
            validation_failed_error_result = double
            expect(validation_failed_error_result).to receive(:errors).and_return([])
            validation_failed_error = Braintree::ValidationsFailed.new(validation_failed_error_result)
            expect(Braintree::Transaction).to receive(:refund!).with(@charge.id).and_raise(validation_failed_error)
          end

  test "raises an error" do
            expect do
              subject.refund!(@charge.id)
            end.to raise_error(ChargeProcessorInvalidRequestError)
          end
        end
      end

  context_ "partially refunding a charge" do
        before do
          @charge = subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                             braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                             225_00,
                                                             0,
                                                             "product-id",
                                                             nil,
                                                             statement_description: "dummy").charge
        end

  context_ "partially refunding a valid charge" do
  test "returns a BraintreeChargeRefund when amount is refundable" do
            expect(subject.refund!(@charge.id, amount_cents: 125_00)).to be_a(BraintreeChargeRefund)
          end

  test "returns the refund id when amount is refundable" do
            expect(subject.refund!(@charge.id, amount_cents: 125_00).id).to match(/^[a-z0-9]+$/)
          end

  test "returns the charge id when amount is refundable" do
            expect(subject.refund!(@charge.id, amount_cents: 125_00).charge_id).to eq(@charge.id)
          end
        end
      end
    end

  context_ "#holder_of_funds" do
      let(:merchant_account) { MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id) }

  test "returns Gumroad" do
        expect(subject.holder_of_funds(merchant_account)).to eq(HolderOfFunds::GUMROAD)
      end
    end
  end
end
