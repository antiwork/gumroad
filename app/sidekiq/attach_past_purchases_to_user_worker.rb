# frozen_string_literal: true

class AttachPastPurchasesToUserWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default

  def perform(user_id)
    user = User.find(user_id)
    return if user.email.blank?

    failure = nil
    Purchase.where(email: user.email, purchaser_id: nil).find_each do |past_purchase|
      attach(past_purchase, user)
    rescue => e
      failure ||= e
    end
    raise failure if failure
  end

  private
    # One unattachable row must not abort the backfill for the rest of the buyer's
    # unlinked purchases. A raise out of the attach (a validation error, a
    # statement timeout) used to end the whole `find_each`: the trailing rows kept
    # `purchaser_id` nil, so paid items stayed missing from the buyer's Library.
    # Attach each row on its own and report the failure, then re-raise so Sidekiq
    # retries the rows that are still unlinked. A `false` return is a deliberate
    # skip (the purchase is reassignment-locked) and does not fail the job.
    def attach(past_purchase, user)
      attached = past_purchase.attach_to_user_and_card(user, nil, nil)
      if attached == false
        Rails.logger.info("AttachPastPurchasesToUserWorker: purchase #{past_purchase.id} left unattached for user #{user.id}")
      end
      attached
    rescue => e
      ErrorNotifier.notify(e, context: { purchase_id: past_purchase.id, user_id: user.id })
      Rails.logger.error("AttachPastPurchasesToUserWorker: purchase #{past_purchase.id} failed to attach for user #{user.id}: #{e.class}: #{e.message}")
      raise
    end
end
