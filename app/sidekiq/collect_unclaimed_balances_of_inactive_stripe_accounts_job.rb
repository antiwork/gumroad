# frozen_string_literal: true

class CollectUnclaimedBalancesOfInactiveStripeAccountsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  # Stripe considers these accounts inactive after >=3 years, so we use the same time frame.
  # Ref: https://support.stripe.com/questions/unclaimed-balances-faqs-for-platforms
  STRIPE_ACCOUNT_INACTIVE_AFTER_DURATION = 3.years

  # Written on every transfer this job makes, and used to recognise our own past transfers when
  # recovering from a run that moved the money but did not finish updating our records.
  TRANSFER_DESCRIPTION = "Collect unclaimed balance of inactive account"

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
      transfer =
        if actual_stripe_account_balance > 0
          # Transfer the money from Stripe connect account to Gumroad's platform Stripe account.
          #
          # The idempotency key guards against two runs overlapping. This job has no uniqueness
          # lock, so a cron double-fire or a manual enqueue alongside the scheduled run can have
          # two executions both read a positive balance before either transfers, and without a key
          # that means two real transfers. Keying on the account and the amount makes the second
          # one replay the first instead. (Ordinary Sidekiq retries are not the risk here: the
          # balance is re-read live above, so once a transfer has succeeded a retry reads 0 and
          # skips this account before reaching the transfer at all.)
          Stripe::Transfer.create({
                                    amount: actual_stripe_account_balance,
                                    currency: Currency::USD,
                                    description: TRANSFER_DESCRIPTION,
                                    destination: STRIPE_PLATFORM_ACCOUNT_ID,
                                  }, {
                                    stripe_account: stripe_account_id,
                                    idempotency_key: "collect_unclaimed_balance_#{stripe_account_id}_#{actual_stripe_account_balance}",
                                  })
        else
          # A zero balance usually just means there is nothing to collect. But it is also what an
          # earlier run of this job leaves behind when it moved the money on Stripe's side and
          # then died before recording it here (the local writes below are rolled back together,
          # so the account is still unmarked). In that state the money is already on Gumroad's
          # platform account while our Balance rows still point at the connected account, and
          # nothing else would ever fix it — so look for a transfer this job made previously and,
          # if there is one, finish the bookkeeping for it now instead of skipping the account.
          previous_transfer_made_by_this_job(stripe_account_id)
        end
      next if transfer.nil?

      # Recording the transfer and moving our own records of the balance have to happen
      # together. The transfer id is what stops the query above from selecting this account
      # again, so if the id were saved and the balances then left behind — a worker killed
      # part-way through the loop, a failing update — the account would never be looked at
      # again and those Balance rows would stay pointing at the dead merchant account forever.
      # Both statements are local database writes, so wrapping them costs nothing.
      ApplicationRecord.transaction do
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

  private
    # Looks for a transfer this job already made out of the given connected account, so a run that
    # moved the money but died before recording it can be finished later.
    #
    # Only our own transfers count. Gumroad makes other connected-account-to-platform transfers —
    # backtax collection and fee-retention debits — and those send no description, so the
    # description we write is what distinguishes ours; recovering one of theirs would record a
    # collection that never happened. The destination filter is applied by Stripe rather than by us
    # so that unrelated transfers can't crowd ours out of the page we ask for. A transfer that has
    # been reversed doesn't count either: the money went back to the seller, so there is nothing to
    # record. We only need the recent ones, because the account is skipped for good as soon as a
    # transfer id is recorded and so at most one unrecorded transfer can exist.
    def previous_transfer_made_by_this_job(stripe_account_id)
      Stripe::Transfer.list({ limit: 10, destination: STRIPE_PLATFORM_ACCOUNT_ID }, { stripe_account: stripe_account_id })
                      .data
                      .find do |transfer|
        transfer.description == TRANSFER_DESCRIPTION &&
          transfer.destination == STRIPE_PLATFORM_ACCOUNT_ID &&
          transfer.amount_reversed.to_i.zero?
      end
    end
end
