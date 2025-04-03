# frozen_string_literal: true

class BraintreeChargeableTransientCustomer < BraintreeChargeableBase
  TRANSIENT_CLIENT_TOKEN_VALIDITY_DURATION = 5.minutes

  attr_accessor :customer_id, :transient_customer_store_key

  def initialize(customer_id, transient_customer_store_key)
    @customer_id = customer_id
    @transient_customer_store_key = transient_customer_store_key
  end

  def self.tokenize_nonce_to_transient_customer(braintree_nonce, transient_customer_store_key)
    return nil if braintree_nonce.blank?

    begin
      braintree_customer = Braintree::Customer.create!(
        credit_card: {
          payment_method_nonce: braintree_nonce
        }
      )
    rescue Braintree::ValidationsFailed, Braintree::ServerError => e
      raise ChargeProcessorInvalidRequestError.new(original_error: e)
    rescue *BraintreeExceptions::UNAVAILABLE => e
      raise ChargeProcessorUnavailableError.new(original_error: e)
    end

    transient_braintree_customer_store = Redis::Namespace.new(:transient_braintree_customer_store, redis: $redis)
    transient_customer_token = ObfuscateIds.encrypt(braintree_customer.id)

    transient_braintree_customer_store.set(transient_customer_store_key, transient_customer_token, ex: BraintreeChargeableTransientCustomer::TRANSIENT_CLIENT_TOKEN_VALIDITY_DURATION)

    new(braintree_customer.id, transient_customer_store_key)
  end

  def self.from_transient_customer_store_key(transient_customer_store_key)
    transient_braintree_customer_store = Redis::Namespace.new(:transient_braintree_customer_store, redis: $redis)

    transient_customer_token = transient_braintree_customer_store.get(transient_customer_store_key)
    raise ChargeProcessorInvalidRequestError, "could not find transient client token" if transient_customer_token.nil?

    new(ObfuscateIds.decrypt(transient_customer_token), transient_customer_store_key)
  end

  def prepare!
    unless @paypal || @card
      @customer = Braintree::Customer.find(customer_id)
      @paypal = @customer.paypal_accounts.first
      @card = @customer.credit_cards.first
    end
    @paypal.present? || @card.present?
  rescue Braintree::ValidationsFailed, Braintree::ServerError => e
    raise ChargeProcessorInvalidRequestError.new(original_error: e)
  rescue Braintree::NotFoundError => e
    raise ChargeProcessorInvalidRequestError.new(original_error: e)
  rescue *BraintreeExceptions::UNAVAILABLE => e
    raise ChargeProcessorUnavailableError.new(original_error: e)
  end
end
