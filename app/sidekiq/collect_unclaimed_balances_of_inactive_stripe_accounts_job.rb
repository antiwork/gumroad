# frozen_string_literal: true

class CollectUnclaimedBalancesOfInactiveStripeAccountsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  # Stripe considers these accounts inactive after >=3 years, so we use the same time frame.
  # Ref: https://support.stripe.com/questions/unclaimed-balances-faqs-for-platforms
  STRIPE_ACCOUNT_INACTIVE_AFTER_DURATION = 3.years

  def perform
    MerchantAccount.stripe
                   .where(country: Compliance::Countries::USA.alpha2)
                   .where.not(charge_processor_merchant_id: nil)
                   .where.not("json_data LIKE '%stripe_connect%'")
                   .where("json_data->>'$.unclaimed_balance_collection_transfer_id' IS NULL")
                   .where("created_at < ?", Time.current - STRIPE_ACCOUNT_INACTIVE_AFTER_DURATION)
                   .find_each do |merchant_account|
      next if [merchant_account.user.sales.successful.last&.created_at.to_i,
               merchant_account.user.payments.completed.last&.created_at.to_i].max > (Time.current - STRIPE_ACCOUNT_INACTIVE_AFTER_DURATION).to_i

      stripe_account_id = merchant_account.charge_processor_merchant_id
      stripe_account = Stripe::Account.retrieve(stripe_account_id)
      next if stripe_account&.type == "standard"
      next if stripe_account&.created.to_i > (Time.current - STRIPE_ACCOUNT_INACTIVE_AFTER_DURATION).to_i

      last_payout_on_stripe = Stripe::Payout.list({ limit: 1 }, { stripe_account: stripe_account_id }).data[0]
      next if last_payout_on_stripe&.created.to_i > (Time.current - STRIPE_ACCOUNT_INACTIVE_AFTER_DURATION).to_i

      last_charge_on_stripe = Stripe::Charge.list({ limit: 1 }, { stripe_account: stripe_account_id }).data[0]
      next if last_charge_on_stripe&.created.to_i > (Time.current - STRIPE_ACCOUNT_INACTIVE_AFTER_DURATION).to_i

      stripe_balance = Stripe::Balance.retrieve({ stripe_account: stripe_account_id })
      stripe_available_balance = stripe_balance["available"][0]["amount"]
      stripe_pending_balance = stripe_balance["pending"][0]["amount"]
      actual_stripe_account_balance = stripe_available_balance + stripe_pending_balance
      next unless actual_stripe_account_balance > 0

      # Transfer the money from Stripe connect account to Gumroad's platform Stripe account.
      transfer = Stripe::Transfer.create({
                                           amount: actual_stripe_account_balance,
                                           currency: Currency::USD,
                                           description: "Collect unclaimed balance of inactive account",
                                           destination: STRIPE_PLATFORM_ACCOUNT_ID,
                                         }, { stripe_account: stripe_account_id })
      merchant_account.update!(unclaimed_balance_collection_transfer_id: transfer.id)

      # Move the unpaid balances in our records to be against Gumroad's platform Stripe account,
      # as the money has been moved to Gumroad's platform Stripe account with the above transfer.
      # Since this balance is at least 3 years old, no refunds or disputes are possible on it now.
      merchant_account.user.unpaid_balances.where(merchant_account_id: merchant_account.id).where(holding_currency: Currency::USD).each do |balance|
        balance.update!(merchant_account_id: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id)
      end
    end
  end
end
