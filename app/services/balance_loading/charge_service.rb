# frozen_string_literal: true

module BalanceLoading
  class ChargeService
    MINIMUM_CHARGE_CENTS = 100 # $1.00 minimum per Stripe

    attr_reader :user, :amount_cents, :refund, :balance_load

    def initialize(user:, amount_cents:, refund: nil)
      @user = user
      @amount_cents = [amount_cents, MINIMUM_CHARGE_CENTS].max
      @refund = refund
    end

    def charge!
      # 1. Find default card
      card = @user.balance_load_credit_cards.active.default_card.first
      raise "No default balance load credit card found for user #{@user.id}" unless card
      raise "Card has expired" if card.expired?

      # 2. Create BalanceLoad record (pending)
      @balance_load = BalanceLoad.create!(
        user: @user,
        balance_load_credit_card: card,
        refund: @refund,
        amount_cents: @amount_cents,
        currency: "usd",
        state: "pending"
      )

      # 3. Charge via Stripe PaymentIntent
      payment_intent = Stripe::PaymentIntent.create({
        amount: @amount_cents,
        currency: "usd",
        customer: card.stripe_customer_id,
        payment_method: card.processor_payment_method_id,
        off_session: true,
        confirm: true,
        description: "Gumroad balance load#{@refund ? " for refund #{@refund.external_id}" : ""}",
        metadata: {
          gumroad_user_id: @user.id,
          balance_load_id: @balance_load.id,
          refund_id: @refund&.id
        }.compact
      })

      # 4. Update balance_load with results
      @balance_load.update!(
        stripe_payment_intent_id: payment_intent.id,
        stripe_charge_id: payment_intent.charges.data.first&.id
      )

      # 5. Handle payment intent status
      case payment_intent.status
      when "succeeded"
        handle_success(payment_intent)
      when "requires_action", "requires_payment_method"
        handle_requires_action(payment_intent)
      else
        handle_failure("Unexpected payment intent status: #{payment_intent.status}")
      end

      @balance_load
    rescue Stripe::CardError => e
      handle_failure(e.message)
      raise
    rescue Stripe::StripeError => e
      handle_failure(e.message)
      raise
    rescue => e
      handle_failure("Unexpected error: #{e.message}")
      raise
    end

    private

    def handle_success(payment_intent)
      charge = payment_intent.charges.data.first
      @balance_load.update!(
        processor_fee_cents: charge.application_fee_amount || 0,
        metadata: { charge_id: charge.id, balance_transaction: charge.balance_transaction }.to_json
      )
      @balance_load.mark_successful!
      Rails.logger.info("BalanceLoad #{@balance_load.id} succeeded: charged $#{@amount_cents / 100.0}")
    end

    def handle_requires_action(payment_intent)
      # Card requires 3DS - queue job to poll for completion
      Rails.logger.info("BalanceLoad #{@balance_load.id} requires action (3DS), queueing job to check status")
      BalanceLoading::ProcessChargeJob.perform_in(5.seconds, @balance_load.id)
    end

    def handle_failure(error_message)
      return unless @balance_load

      @balance_load.update!(error_message:)
      @balance_load.mark_failed!
      Rails.logger.error("BalanceLoad #{@balance_load.id} failed: #{error_message}")
    end
  end
end
