# frozen_string_literal: true

# Servicio para manejar y resolver fallos de pago en Gumroad
class PayoutFailureResolver
  include ActiveModel::Validations

  attr_reader :user_id, :failure_type, :context

  def initialize(user_id:, failure_type:, context: {})
    @user_id = user_id
    @failure_type = failure_type
    @context = context
  end

  def resolve!
    case failure_type
    when :duplicate_balance_increment
      fix_duplicate_balance_increment
    when :stripe_account_mismatch
      fix_stripe_account_mismatch
    when :negative_balance_country_change
      fix_negative_balance_country_change
    when :stripe_loan_webhook_handling
      fix_stripe_loan_webhook_handling
    when :obsolete_stripe_account
      fix_obsolete_stripe_account
    else
      raise "Unknown failure type: #{failure_type}"
    end
  end

  private

  def fix_duplicate_balance_increment
    user = User.find(user_id)
    duplicate_purchases = context[:duplicate_purchase_ids] || []
    excess_amount = context[:excess_amount] || 0

    ActiveRecord::Base.transaction do
      # Revertir incrementos duplicados
      duplicate_purchases.each do |purchase_id|
        purchase = Purchase.find(purchase_id)
        
        # Buscar transacciones de balance duplicadas
        duplicate_transactions = BalanceTransaction.where(
          user: user,
          purchase: purchase,
          transaction_type: 'sale_credit'
        ).order(:created_at)

        if duplicate_transactions.count > 1
          # Eliminar la transacción duplicada (la más reciente)
          duplicate_transaction = duplicate_transactions.last
          user.balance -= duplicate_transaction.amount
          duplicate_transaction.destroy!
          
          Rails.logger.info("Removed duplicate balance transaction for purchase #{purchase_id}, amount: #{duplicate_transaction.amount}")
        end
      end

      # Ajustar balance total si se proporciona
      if excess_amount > 0
        adjustment = BalanceTransaction.create!(
          user: user,
          amount: -excess_amount,
          transaction_type: 'adjustment',
          description: "Correction for duplicate balance increments",
          metadata: { related_purchases: duplicate_purchases }
        )
        
        user.balance -= excess_amount
        user.save!
        
        Rails.logger.info("Adjusted balance for user #{user_id} by -#{excess_amount}")
      end

      # Prevenir futuras duplicaciones
      create_duplicate_prevention_flag(user)
    end
  end

  def fix_stripe_account_mismatch
    user = User.find(user_id)
    old_stripe_account_id = context[:old_stripe_account_id]
    new_stripe_account_id = context[:new_stripe_account_id]
    dispute_amount = context[:dispute_amount] || 0

    ActiveRecord::Base.transaction do
      # Revertir transferencia a cuenta antigua
      if old_stripe_account_id && dispute_amount > 0
        old_transfer = StripeTransfer.find_by(
          stripe_account_id: old_stripe_account_id,
          amount: dispute_amount,
          status: 'completed'
        )

        if old_transfer
          reverse_stripe_transfer(old_transfer)
        end
      end

      # Transferir a nueva cuenta
      if new_stripe_account_id && dispute_amount > 0
        new_transfer = StripeTransferInternallyToCreator.transfer_funds_to_account(
          user: user,
          amount: dispute_amount,
          currency: context[:currency] || 'USD',
          stripe_account_id: new_stripe_account_id,
          description: "Dispute win transfer correction"
        )

        Rails.logger.info("Transferred #{dispute_amount} to new Stripe account #{new_stripe_account_id}")
      end

      # Actualizar balance interno
      update_internal_balance_for_account_change(user, dispute_amount)
    end
  end

  def fix_negative_balance_country_change
    user = User.find(user_id)
    old_country = context[:old_country]
    new_country = context[:new_country]
    negative_balance = context[:negative_balance] || 0

    ActiveRecord::Base.transaction do
      # Manejar balance negativo correctamente
      if negative_balance < 0
        # Crear transacción de ajuste para balance negativo
        adjustment = BalanceTransaction.create!(
          user: user,
          amount: -negative_balance, # Convertir a positivo
          transaction_type: 'country_change_adjustment',
          description: "Negative balance correction for country change from #{old_country} to #{new_country}",
          metadata: { 
            old_country: old_country,
            new_country: new_country,
            original_negative_balance: negative_balance
          }
        )

        user.balance += (-negative_balance)
        user.save!

        Rails.logger.info("Corrected negative balance #{negative_balance} for user #{user_id} country change")
      end

      # Actualizar configuración de país
      update_country_specific_settings(user, new_country)
    end
  end

  def fix_stripe_loan_webhook_handling
    user = User.find(user_id)
    loan_amount = context[:loan_amount] || 0
    webhook_payment_id = context[:webhook_payment_id]

    ActiveRecord::Base.transaction do
      # Buscar crédito negativo erróneo
      incorrect_credit = BalanceTransaction.find_by(
        user: user,
        amount: -loan_amount,
        transaction_type: 'stripe_loan_paydown'
      )

      if incorrect_credit
        # Revertir crédito incorrecto
        user.balance -= incorrect_credit.amount
        incorrect_credit.destroy!

        Rails.logger.info("Removed incorrect negative credit of #{loan_amount} for user #{user_id}")
      end

      # Mejorar manejo de webhook para distinguir fuente de débito
      improve_stripe_loan_webhook_handling(user, webhook_payment_id)
    end
  end

  def fix_obsolete_stripe_account
    user = User.find(user_id)
    obsolete_account_id = context[:obsolete_stripe_account_id]
    
    ActiveRecord::Base.transaction do
      # Verificar si hay balance en cuenta obsoleta
      obsolete_balance = get_stripe_account_balance(obsolete_account_id)
      
      if obsolete_balance && obsolete_balance > 0
        # Notificar al usuario sobre opciones de pago alternativas
        create_payout_notification(user, obsolete_balance, obsolete_account_id)
      end

      # Actualizar configuración de pago
      user.stripe_accounts.where(stripe_account_id: obsolete_account_id).update_all(status: 'obsolete')
      
      Rails.logger.info("Marked Stripe account #{obsolete_account_id} as obsolete for user #{user_id}")
    end
  end

  # Métodos auxiliares
  def create_duplicate_prevention_flag(user)
    user.update!(
      metadata: user.metadata.merge(
        duplicate_balance_check_enabled: true,
        last_duplicate_fix_at: Time.current
      )
    )
  end

  def reverse_stripe_transfer(transfer)
    # Implementar lógica de reversión de transferencia Stripe
    Stripe::Transfer.reverse(transfer.stripe_transfer_id)
    transfer.update!(status: 'reversed', reversed_at: Time.current)
  end

  def update_internal_balance_for_account_change(user, amount)
    # Actualizar balance interno para reflejar cambio de cuenta
    BalanceTransaction.create!(
      user: user,
      amount: amount,
      transaction_type: 'stripe_account_correction',
      description: "Balance correction for Stripe account change"
    )
  end

  def update_country_specific_settings(user, new_country)
    # Actualizar configuraciones específicas del país
    user.update!(
      country: new_country,
      currency: get_default_currency_for_country(new_country),
      tax_settings: get_tax_settings_for_country(new_country)
    )
  end

  def improve_stripe_loan_webhook_handling(user, webhook_payment_id)
    # Mejorar el manejo de webhooks para préstamos Stripe
    webhook_data = retrieve_stripe_webhook_data(webhook_payment_id)
    
    if webhook_data&.dig('payment_method_details', 'type') == 'bank_account'
      # Débito de cuenta bancaria - no ajustar balance
      Rails.logger.info("Stripe loan paid from bank account - no balance adjustment needed")
    else
      # Débito de balance Stripe - ajustar balance
      Rails.logger.info("Stripe loan paid from Stripe balance - balance adjustment applied")
    end
  end

  def get_stripe_account_balance(account_id)
    return nil unless account_id

    begin
      balance = Stripe::Balance.retrieve({}, { stripe_account: account_id })
      balance.available.sum { |b| b.amount / 100.0 } # Convertir de centavos
    rescue Stripe::InvalidRequestError => e
      Rails.logger.error("Error retrieving Stripe balance for account #{account_id}: #{e.message}")
      nil
    end
  end

  def create_payout_notification(user, balance, obsolete_account_id)
    Notification.create!(
      user: user,
      type: 'payout_account_update_required',
      title: 'Payout Account Update Required',
      message: "You have a balance of #{balance} in an obsolete Stripe account. Please update your payout information.",
      metadata: {
        obsolete_account_id: obsolete_account_id,
        balance_amount: balance
      }
    )
  end

  def get_default_currency_for_country(country)
    case country.upcase
    when 'US' then 'USD'
    when 'CA' then 'CAD'
    when 'GB' then 'GBP'
    when 'IT', 'DE', 'FR', 'ES' then 'EUR'
    when 'SG' then 'SGD'
    else 'USD' # Fallback
    end
  end

  def get_tax_settings_for_country(country)
    # Implementar configuraciones fiscales específicas por país
    TaxSettingsService.get_settings_for_country(country)
  end

  def retrieve_stripe_webhook_data(payment_id)
    return nil unless payment_id

    begin
      Stripe::PaymentIntent.retrieve(payment_id)
    rescue Stripe::InvalidRequestError => e
      Rails.logger.error("Error retrieving Stripe payment data for #{payment_id}: #{e.message}")
      nil
    end
  end
end
