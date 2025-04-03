# frozen_string_literal: true

class HandleStripeAutodebitForNegativeBalance
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(stripe_event_id, stripe_connect_account_id, stripe_payout_id)
    @stripe_connect_account_id = stripe_connect_account_id
    @stripe_payout_id = stripe_payout_id

    if debit_success?
      StripePayoutProcessor.handle_stripe_negative_balance_debit_event(stripe_connect_account_id, stripe_payout_id)
    elsif debit_failed?
      # The debit payout that was once reported as `paid`, has now transitioned to `failed`.
      # We waited for it to either complete its balance transaction, or to fail. It failed, so nothing for us to do.
    else
      raise "Timed out waiting for payout to become finalized (to transition to `failed` state or its balance transaction "\
              "to transition to `available` state). Stripe event ID: #{stripe_event_id}."
    end
  end

  private
    attr_reader :stripe_payout_id, :stripe_connect_account_id

    def debit_success?
      balance_transaction_completed? && (payout["status"] == "paid")
    end

    def balance_transaction_completed?
      payout["balance_transaction"]["status"] == "available"
    end

    def debit_failed?
      payout["status"] == "failed"
    end

    def payout
      @_payout ||= Stripe::Payout.retrieve(
        { id: stripe_payout_id, expand: %w[balance_transaction] },
        { stripe_account: stripe_connect_account_id }
      )
    end
end
