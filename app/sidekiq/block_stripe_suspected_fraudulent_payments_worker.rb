# frozen_string_literal: true

class BlockStripeSuspectedFraudulentPaymentsWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  TRAILING_DAYS = 90
  STRIPE_EMAIL_SENDER = "notifications@stripe.com"
  HELPER_NOTE_CONTENT = "Done with code"
  POSSIBLE_CONVERSATION_SUBJECTS = [
    "Suspected fraudulent payments on your Stripe account",
    "Suspected fraudulent payment on your Stripe account",
  ]

  def perform(conversation_id, email_from, body)
    return unless email_from == STRIPE_EMAIL_SENDER

    records = parse_payment_records_from_body(body)
    return if records.empty?

    handle_suspected_fraudulent_payments(records)
    helper.add_note(conversation_id:, message: HELPER_NOTE_CONTENT)
    helper.close_conversation(conversation_id:)
  end

  private
    def helper
      @helper ||= Helper::Client.new
    end

    def handle_suspected_fraudulent_payments(records)
      records.each do |transaction_id|
        Purchase.created_after(TRAILING_DAYS.days.ago)
          .not_fully_refunded
          .not_chargedback
          .where(stripe_transaction_id: transaction_id)
          .each do |purchase|
            purchase.refund_for_fraud!(GUMROAD_ADMIN_ID)
            next if purchase.buyer_blocked?

            comment_content = "Buyer blocked by Helper webhook"
            purchase.block_buyer!(blocking_user_id: GUMROAD_ADMIN_ID, comment_content:)
          end
      end
    end

    def parse_payment_records_from_body(body)
      body.scan(/>(ch_[a-zA-Z\d]{8,})<\/a>/).flatten
    rescue StandardError => error
      Bugsnag.notify error
      []
    end
end
