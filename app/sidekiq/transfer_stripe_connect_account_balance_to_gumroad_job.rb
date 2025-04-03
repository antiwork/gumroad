# frozen_string_literal: true

class TransferStripeConnectAccountBalanceToGumroadJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(merchant_account_id, amount_cents_to_transfer_usd)
    return unless merchant_account_id.present?
    return unless amount_cents_to_transfer_usd > 0

    merchant_account = MerchantAccount.find(merchant_account_id)
    return unless merchant_account&.holder_of_funds == HolderOfFunds::STRIPE
    return unless merchant_account.charge_processor_merchant_id.present?

    stripe_account_id = merchant_account.charge_processor_merchant_id

    if merchant_account.country == Compliance::Countries::USA.alpha2
      # For Gumroad-controlled Stripe accounts in the US, we can make new debit transfers.
      Stripe::Transfer.create({ amount: amount_cents_to_transfer_usd, currency: "usd", destination: STRIPE_PLATFORM_ACCOUNT_ID, },
                              { stripe_account: stripe_account_id })
    else
      # For non-US Gumroad-controlled Stripe accounts, we cannot make new debit transfers, so we reverse old transfers.
      transferred_amount_cents_usd = 0

      # First reverse transfers made from Gumroad's account for past payouts.
      transfer_ids = merchant_account.user.payments.completed
                                     .where(stripe_connect_account_id: stripe_account_id)
                                     .order(:created_at)
                                     .pluck(:stripe_internal_transfer_id)
      transfer_ids.compact_blank.each do |transfer_id|
        break if transferred_amount_cents_usd >= amount_cents_to_transfer_usd

        transfer = Stripe::Transfer.retrieve(transfer_id) rescue nil
        next unless transfer.present?
        next unless transfer.currency == "usd"

        amount_cents_available_to_reverse = transfer.amount - transfer.amount_reversed
        next unless amount_cents_available_to_reverse > 0

        reversal_amount_cents = [amount_cents_available_to_reverse, amount_cents_to_transfer_usd - transferred_amount_cents_usd].min
        Stripe::Transfer.create_reversal(transfer_id, { amount: reversal_amount_cents })
        transferred_amount_cents_usd += reversal_amount_cents
      end

      return if transferred_amount_cents_usd >= amount_cents_to_transfer_usd

      # If amount still left to be transferred, reverse transfers associated with purchases > 7 days old.
      starting_after = nil
      until transferred_amount_cents_usd >= amount_cents_to_transfer_usd
        transfers = Stripe::Transfer.list(destination: stripe_account_id, created: { 'lt': 7.days.ago.to_i }, limit: 100, starting_after:)
        break unless transfers.present?

        transfers.each do |transfer|
          starting_after = transfer.id
          break if transferred_amount_cents_usd >= amount_cents_to_transfer_usd
          next unless transfer.currency == "usd"

          amount_cents_available_to_reverse = transfer.amount - transfer.amount_reversed
          next unless amount_cents_available_to_reverse > 0

          reversal_amount_cents = [amount_cents_available_to_reverse - 1, amount_cents_to_transfer_usd - transferred_amount_cents_usd].min
          Stripe::Transfer.create_reversal(transfer.id, { amount: reversal_amount_cents })
          transferred_amount_cents_usd += reversal_amount_cents
        end
      end

      remaining_cents_usd = amount_cents_to_transfer_usd - transferred_amount_cents_usd
      return unless remaining_cents_usd > 0

      # If amount still left to be transferred, retry in 7 days.
      TransferStripeConnectAccountBalanceToGumroadJob.perform_in(7.days, merchant_account_id, remaining_cents_usd)
    end
  end
end
