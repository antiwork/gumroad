# frozen_string_literal: true

module BalanceLoading
  class PaymentMethodService
    attr_reader :user

    def initialize(user:)
      @user = user
    end

    # Add new card from Stripe payment method
    def add_card(payment_method_id:, set_as_default: true)
      # 1. Retrieve payment method from Stripe
      payment_method = Stripe::PaymentMethod.retrieve(payment_method_id)

      # 2. Attach to customer (create if needed)
      customer_id = ensure_stripe_customer
      payment_method.attach(customer: customer_id) unless payment_method.customer

      # 3. Create BalanceLoadCreditCard record
      card = BalanceLoadCreditCard.new(
        user: @user,
        stripe_customer_id: customer_id,
        processor_payment_method_id: payment_method.id,
        stripe_fingerprint: payment_method.card.fingerprint,
        visual: format_visual(payment_method.card.last4),
        card_type: payment_method.card.brand.downcase,
        expiry_month: payment_method.card.exp_month,
        expiry_year: payment_method.card.exp_year,
        card_country: payment_method.card.country,
        is_default: set_as_default
      )

      # 4. If setting as default, unset other defaults
      if set_as_default
        BalanceLoadCreditCard.where(user: @user, is_default: true).active.update_all(is_default: false)
      end

      card.save!
      card
    rescue Stripe::StripeError => e
      Rails.logger.error("Failed to add balance load card: #{e.message}")
      raise
    end

    # Update existing card (really just updates default status or replaces payment method)
    def update_card(card_id:, payment_method_id: nil, set_as_default: nil)
      card = @user.balance_load_credit_cards.active.find(card_id)

      # If new payment method provided, update card details
      if payment_method_id.present?
        payment_method = Stripe::PaymentMethod.retrieve(payment_method_id)
        customer_id = ensure_stripe_customer
        payment_method.attach(customer: customer_id) unless payment_method.customer

        # Detach old payment method
        begin
          Stripe::PaymentMethod.detach(card.processor_payment_method_id) if card.processor_payment_method_id
        rescue Stripe::StripeError => e
          Rails.logger.warn("Could not detach old payment method: #{e.message}")
        end

        card.update!(
          processor_payment_method_id: payment_method.id,
          stripe_fingerprint: payment_method.card.fingerprint,
          visual: format_visual(payment_method.card.last4),
          card_type: payment_method.card.brand.downcase,
          expiry_month: payment_method.card.exp_month,
          expiry_year: payment_method.card.exp_year,
          card_country: payment_method.card.country
        )
      end

      # Update default status if requested
      if !set_as_default.nil? && set_as_default && !card.is_default?
        BalanceLoadCreditCard.where(user: @user, is_default: true).active.update_all(is_default: false)
        card.update!(is_default: true)
      elsif !set_as_default.nil? && !set_as_default && card.is_default?
        # If unsetting default, set another as default
        card.update!(is_default: false)
        other_card = @user.balance_load_credit_cards.active.where.not(id: card.id).first
        other_card&.update!(is_default: true)
      end

      card
    rescue Stripe::StripeError => e
      Rails.logger.error("Failed to update balance load card: #{e.message}")
      raise
    end

    # Remove card (soft delete)
    def remove_card(card_id:)
      card = @user.balance_load_credit_cards.active.find(card_id)

      # If removing default, set another as default
      if card.is_default?
        other_card = @user.balance_load_credit_cards.active.where.not(id: card.id).first
        other_card&.update!(is_default: true)
      end

      card.soft_delete!

      # Optionally detach from Stripe
      begin
        Stripe::PaymentMethod.detach(card.processor_payment_method_id) if card.processor_payment_method_id
      rescue Stripe::StripeError => e
        Rails.logger.warn("Could not detach payment method from Stripe: #{e.message}")
      end

      card
    end

    private

    def ensure_stripe_customer
      # Check if user already has a stripe_customer_id_for_balance_loading
      return @user.stripe_customer_id_for_balance_loading if @user.stripe_customer_id_for_balance_loading.present?

      # Create new Stripe customer for balance loading
      customer = Stripe::Customer.create(
        email: @user.email,
        name: @user.name,
        metadata: { gumroad_user_id: @user.id, purpose: "balance_loading" }
      )

      @user.update!(stripe_customer_id_for_balance_loading: customer.id)
      customer.id
    end

    def format_visual(last4)
      "•••• •••• •••• #{last4}"
    end
  end
end
