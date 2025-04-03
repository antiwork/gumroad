# frozen_string_literal: true

require "spec_helper"

describe BraintreeChargeProcessor, :vcr do
  describe ".charge_processor_id" do
    it "returns 'stripe'" do
      expect(BraintreeChargeProcessor.charge_processor_id).to eq "braintree"
    end
  end

  let(:braintree_chargeable) do
    chargeable = BraintreeChargeableNonce.new(Braintree::Test::Nonce::PayPalFuturePayment, nil)
    chargeable.prepare!
    Chargeable.new([chargeable])
  end

  describe "#get_chargeable_for_params" do
    describe "with invalid params" do
      it "returns nil" do
        expect(subject.get_chargeable_for_params({}, nil)).to be(nil)
      end
    end

    describe "with only nonce" do
      let(:paypal_nonce) { Braintree::Test::Nonce::PayPalFuturePayment }

      it "returns a chargeable nonce" do
        expect(BraintreeChargeableNonce).to receive(:new).with(paypal_nonce, nil).and_call_original

        expect(subject.get_chargeable_for_params({ braintree_nonce: paypal_nonce }, nil)).to be_a(BraintreeChargeableNonce)
      end
    end

    describe "with transient customer key", :vcr do
      before do
        @frozen_time = Time.current
        travel_to(@frozen_time) do
          @braintree_transient_customer_store_key = "braintree_transient_customer_store_key"
          BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer(Braintree::Test::Nonce::PayPalFuturePayment, @braintree_transient_customer_store_key)
        end
      end

      it "returns a transient customer" do
        travel_to(@frozen_time) do
          expect(subject.get_chargeable_for_params({ braintree_transient_customer_store_key: @braintree_transient_customer_store_key }, nil)).to be_a(BraintreeChargeableTransientCustomer)
        end
      end
    end

    describe "with braintree device data for fraud check on braintree's side" do
      let(:dummy_device_data) { { dummy_session_id: "dummy" }.to_json }

      describe "with a braintree nonce" do
        let(:paypal_nonce) { Braintree::Test::Nonce::PayPalFuturePayment }

        it "returns a chargeable nonce with the device data JSON string set" do
          expect(BraintreeChargeableNonce).to receive(:new).with(paypal_nonce, nil).and_call_original
          actual_chargeable = subject.get_chargeable_for_params({ braintree_nonce: paypal_nonce,
                                                                  braintree_device_data: dummy_device_data }, nil)
          expect(actual_chargeable).to be_a(BraintreeChargeableNonce)
          expect(actual_chargeable.braintree_device_data).to eq(dummy_device_data)
        end
      end

      describe "with a transient customer store key with the device data JSON string set" do
        before do
          @frozen_time = Time.current
          travel_to(@frozen_time) do
            @braintree_transient_customer_store_key = "braintree_transient_customer_store_key"
            BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer(Braintree::Test::Nonce::PayPalFuturePayment, @braintree_transient_customer_store_key)
          end
        end

        it "returns a transient customer" do
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

  describe "#get_chargeable_for_data" do
    describe "with customer id as retreivable token" do
      it "returns a credit card with the reusable token set" do
        expect(BraintreeChargeableCreditCard).to receive(:new)
                                                     .with(braintree_chargeable.reusable_token_for!(BraintreeChargeProcessor.charge_processor_id, nil), nil, nil, nil, nil, nil, nil, nil, nil, nil)
                                                     .and_call_original

        expect(subject.get_chargeable_for_data(braintree_chargeable.reusable_token_for!(BraintreeChargeProcessor.charge_processor_id, nil), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil))
            .to be_a(BraintreeChargeableCreditCard)
      end
    end
  end

  describe "#get_charge" do
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

    describe "with an invalid charge id" do
      it "throws a charge processor invalid exception" do
        expect do
          subject.get_charge("invalid")
        end.to raise_error(ChargeProcessorInvalidRequestError)
      end
    end

    describe "with a valid charge id" do
      it "retrieves and returns a braintree charge object" do
        actual_charge = subject.get_charge(braintree_charge_txn.id)

        expect(actual_charge).to_not be(nil)
        expect(actual_charge).to be_a(BraintreeCharge)
        expect(actual_charge.charge_processor_id).to eq(BraintreeChargeProcessor.charge_processor_id)
        expect(actual_charge.zip_check_result).to be(nil)
        expect(actual_charge.id).to eq(braintree_charge_txn.id)
        expect(actual_charge.fee).to be(nil)
        expect(actual_charge.card_fingerprint).to eq("paypal_jane.doe@example.com")
      end
    end

    describe "when the charge processor is unavailable" do
      before do
        expect(Braintree::Transaction).to receive(:find).and_raise(Braintree::ServiceUnavailableError)
      end

      it "raises an error" do
        expect { subject.get_charge("a-charge-id") }.to raise_error(ChargeProcessorUnavailableError)
      end
    end
  end

  describe "#search_charge" do
    it "returns a Braintree::Transaction object with details of the transaction attached to the given purchase" do
      allow_any_instance_of(Purchase).to receive(:external_id).and_return("50WuYB5aQYhDx2gzaxhP-Q==")

      charge = subject.search_charge(purchase: create(:purchase, charge_processor_id: BraintreeChargeProcessor.charge_processor_id))

      expect(charge).to be_a(Braintree::Transaction)
      expect(charge.id).to eq("f4ajns4e")
      expect(charge.status).to eq("settled")
    end

    it "returns nil if no transaction is found for the given purchase" do
      allow_any_instance_of(Purchase).to receive(:external_id).and_return(ObfuscateIds.encrypt(1234567890))

      expect(subject.search_charge(purchase: create(:purchase, charge_processor_id: BraintreeChargeProcessor.charge_processor_id))).to be(nil)
    end
  end

  describe "#create_payment_intent_or_charge!" do
    let(:braintree_merchant_account) { MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id) }

    describe "successful charging" do
      it "charges the card and returns a braintree charge" do
        actual_charge = subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                                 braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                                 225_00,
                                                                 0,
                                                                 "product-id",
                                                                 nil,
                                                                 statement_description: "dummy").charge

        expect(actual_charge).to_not be(nil)
        expect(actual_charge).to be_a(BraintreeCharge)

        expect(actual_charge.charge_processor_id).to eq("braintree")
        expect(actual_charge.id).to_not be(nil)

        actual_txn = Braintree::Transaction.find(actual_charge.id)
        expect(actual_txn).to_not be(nil)
        expect(actual_txn.amount).to eq(225.0)
        expect(actual_txn.customer_details.id).to eq(braintree_chargeable.reusable_token_for!(BraintreeChargeProcessor.charge_processor_id, nil))
      end
    end

    describe "successful charging with device data passed to braintree" do
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

      it "charges the card and returns a braintree charge" do
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

        expect(actual_charge).to_not be(nil)
        expect(actual_charge).to be_a(BraintreeCharge)

        expect(actual_charge.charge_processor_id).to eq("braintree")
        expect(actual_charge.id).to_not be(nil)

        actual_txn = Braintree::Transaction.find(actual_charge.id)
        expect(actual_txn).to_not be(nil)
        expect(actual_txn.amount).to eq(225.0)
        expect(actual_txn.customer_details.id).to eq(braintree_chargeable.reusable_token_for!(BraintreeChargeProcessor.charge_processor_id, nil))
      end
    end

    describe "unsuccessful charging" do
      describe "when the charge processor is unavailable" do
        before do
          expect(Braintree::Transaction).to receive(:sale).and_raise(Braintree::ServiceUnavailableError)
        end

        it "raises an error" do
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

      describe "failures emulated by payment amount" do
        describe "when card is declined" do
          it "returns an error" do
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

        describe "when paypal account is unsupported" do
          it "returns an error" do
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

        describe "when paypal payment instrument is unsupported" do
          it "returns an error" do
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

        describe "when paypal payment instrument is unsupported" do
          it "returns an error" do
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

        describe "when paypal payment instrument is unsupported" do
          it "returns an error" do
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

        describe "when paypal payment is settlement declined" do
          it "returns an error" do
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

  describe "#refund!" do
    let(:braintree_merchant_account) { MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id) }

    describe "when the charge processor is unavailable" do
      before do
        expect(Braintree::Transaction).to receive(:refund!).and_raise(Braintree::ServiceUnavailableError)
      end

      it "raises an error" do
        expect { subject.refund!("dummy") }.to raise_error(ChargeProcessorUnavailableError)
      end
    end

    describe "refunding an non-existant transaction" do
      it "raises an error" do
        expect do
          subject.refund!("invalid-charge-id")
        end.to raise_error(ChargeProcessorInvalidRequestError)
      end
    end

    describe "fully refunding a charge" do
      before do
        @charge = subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                           braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                           225_00,
                                                           0,
                                                           "product-id",
                                                           nil,
                                                           statement_description: "dummy").charge
      end

      describe "fully refunding a charge is successful" do
        it "returns a BraintreeChargeRefund object" do
          expect(subject.refund!(@charge.id)).to be_a(BraintreeChargeRefund)
        end

        it "returns the refund id" do
          expect(subject.refund!(@charge.id).id).to match(/^[a-z0-9]+$/)
        end

        it "returns the charge id" do
          expect(subject.refund!(@charge.id).charge_id).to eq(@charge.id)
        end
      end

      describe "refunding an already fully refunded charge" do
        before do
          subject.refund!(@charge.id)
        end

        it "raises an error" do
          expect do
            subject.refund!(@charge.id)
          end.to raise_error(ChargeProcessorAlreadyRefundedError)
        end
      end

      describe "refunding an already chargedback charge, which will return a ValidationFailed without errors specified" do
        before do
          validation_failed_error_result = double
          expect(validation_failed_error_result).to receive(:errors).and_return([])
          validation_failed_error = Braintree::ValidationsFailed.new(validation_failed_error_result)
          expect(Braintree::Transaction).to receive(:refund!).with(@charge.id).and_raise(validation_failed_error)
        end

        it "raises an error" do
          expect do
            subject.refund!(@charge.id)
          end.to raise_error(ChargeProcessorInvalidRequestError)
        end
      end
    end

    describe "partially refunding a charge" do
      before do
        @charge = subject.create_payment_intent_or_charge!(braintree_merchant_account,
                                                           braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id),
                                                           225_00,
                                                           0,
                                                           "product-id",
                                                           nil,
                                                           statement_description: "dummy").charge
      end

      describe "partially refunding a valid charge" do
        it "returns a BraintreeChargeRefund when amount is refundable" do
          expect(subject.refund!(@charge.id, amount_cents: 125_00)).to be_a(BraintreeChargeRefund)
        end

        it "returns the refund id when amount is refundable" do
          expect(subject.refund!(@charge.id, amount_cents: 125_00).id).to match(/^[a-z0-9]+$/)
        end

        it "returns the charge id when amount is refundable" do
          expect(subject.refund!(@charge.id, amount_cents: 125_00).charge_id).to eq(@charge.id)
        end
      end
    end
  end

  describe "#holder_of_funds" do
    let(:merchant_account) { MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id) }

    it "returns Gumroad" do
      expect(subject.holder_of_funds(merchant_account)).to eq(HolderOfFunds::GUMROAD)
    end
  end
end
