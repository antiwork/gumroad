# frozen_string_literal: true

class HandlePayoutReversedWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(payment_id, reversing_payout_id, stripe_connect_account_id)
    @reversing_payout_id = reversing_payout_id
    @stripe_connect_account_id = stripe_connect_account_id

    if reversing_payout_succeeded?
      StripePayoutProcessor.handle_stripe_event_payout_reversed(Payment.find(payment_id), reversing_payout_id)
    elsif reversing_payout_failed?
      # The reversing payout that was once reported as `paid`, has now transitioned to `failed`.
      # We waited for it to either complete its balance transaction, or to fail. It failed, so nothing for us to do.
    else
      raise "Timed out waiting for reversing payout to become finalized (to transition to `failed` state or its balance transaction "\
              "to transition to `available` state). Payment ID: #{payment_id}. Reversing payout ID: #{reversing_payout_id}"
    end
  end

  private
    attr_reader :reversing_payout_id, :stripe_connect_account_id

    def reversing_payout_succeeded?
      balance_transaction_completed? && (reversing_payout["status"] == "paid")
    end

    def balance_transaction_completed?
      reversing_payout["balance_transaction"]["status"] == "available"
    end

    def reversing_payout_failed?
      reversing_payout["status"] == "failed"
    end

    def reversing_payout
      @_reversing_payout ||= Stripe::Payout.retrieve(
        { id: reversing_payout_id, expand: %w[balance_transaction] },
        { stripe_account: stripe_connect_account_id }
      )
    end
end
