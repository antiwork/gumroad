# frozen_string_literal: true

require "test_helper"

class BraintreeChargeableTransientCustomerTest < ActiveSupport::TestCase
  self.described_class = BraintreeChargeableTransientCustomer
  self.rspec_metadata = { vcr: true }


  context_ BraintreeChargeableTransientCustomer, :vcr do
    let(:transient_customer_store_key) { "transient-customer-token-key" }

  context_ "tokenize_nonce_to_transient_customer" do
  test "stores the customer id with an expiry in redis" do
        frozen_time = Time.current
        travel_to(frozen_time) do
          result = BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer(Braintree::Test::Nonce::PayPalFuturePayment,
                                                                                             transient_customer_store_key)

          expect(result).not_to be(nil)
          expect(result).to be_a(BraintreeChargeableTransientCustomer)
          transient_braintree_customer_store = Redis::Namespace.new(:transient_braintree_customer_store, redis: $redis)

          transient_customer_token = transient_braintree_customer_store.get(transient_customer_store_key)
          expect(transient_customer_token).not_to be(nil)
        end
      end

  test "stores the value in redis with expiry" do
        braintree_double = double("braintree")
        allow(braintree_double).to receive(:id).and_return(123)
        allow(Braintree::Customer).to receive(:create!).and_return(braintree_double)

        expect_any_instance_of(Redis::Namespace).to receive(:set).with(transient_customer_store_key, ObfuscateIds.encrypt(123), ex: 5.minutes)

        BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer(Braintree::Test::Nonce::PayPalFuturePayment, transient_customer_store_key)
      end

  test "returns an error message when the nonce is invalid" do
        expect do
          BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer("invalid", transient_customer_store_key)
        end.to raise_error(ChargeProcessorInvalidRequestError)
      end

  test "returns an error message when the charge processor is down" do
        expect(Braintree::Customer).to receive(:create!).and_raise(Braintree::ServiceUnavailableError)

        expect do
          BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer(Braintree::Test::Nonce::PayPalFuturePayment, transient_customer_store_key)
        end.to raise_error(ChargeProcessorUnavailableError)
      end
    end

  context_ "from_transient_customer_store_key" do
      before do
        @frozen_time = Time.current
        travel_to(@frozen_time) do
          BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer(Braintree::Test::Nonce::PayPalFuturePayment,
                                                                                    transient_customer_store_key)
        end
      end

  test "raises an error if transient customer storage does not have any contents" do
        expect do
          BraintreeChargeableTransientCustomer.from_transient_customer_store_key("this-key-doesnt-exists")
        end.to raise_error(ChargeProcessorInvalidRequestError)
      end

  context_ "valid, non-expired storage entry exists" do
  test "returns a constructed object if the storage contents have not expired" do
          travel_to(@frozen_time) do
            transient_customer = BraintreeChargeableTransientCustomer.from_transient_customer_store_key(transient_customer_store_key)
            expect(transient_customer).to be_a(BraintreeChargeableTransientCustomer)
          end
        end
      end
    end

  context_ "#prepare!" do
      before do
        @frozen_time = Time.current
        travel_to(@frozen_time) do
          BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer(Braintree::Test::Nonce::PayPalFuturePayment,
                                                                                    transient_customer_store_key)
        end
      end

  test "throws a validation failure on using an invalid customer ID" do
        expect do
          chargeable = BraintreeChargeableTransientCustomer.new("invalid", nil)
          chargeable.prepare!
        end.to raise_exception(ChargeProcessorInvalidRequestError)
      end

  test "succeeds as long as we can find a customer" do
        travel_to(@frozen_time + 2.minutes) do
          transient_customer = BraintreeChargeableTransientCustomer.from_transient_customer_store_key(transient_customer_store_key)
          expect(transient_customer).to be_a(BraintreeChargeableTransientCustomer)

          transient_customer.prepare!

          expect(transient_customer.fingerprint).to eq("paypal_jane.doe@example.com")
        end
      end
    end

  context_ "#charge_processor_id" do
      let(:chargeable) { BraintreeChargeableTransientCustomer.new(nil, nil) }

  test "returns 'stripe'" do
        expect(chargeable.charge_processor_id).to eq "braintree"
      end
    end
  end
end
