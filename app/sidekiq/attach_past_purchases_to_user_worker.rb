# frozen_string_literal: true

class AttachPastPurchasesToUserWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default

  # `email` pins the address the user confirmed; the account email can change before the job runs.
  def perform(user_id, email = nil)
    user = User.find(user_id)
    email ||= user.email
    return if email.blank?

    failure = nil
    Purchase.where(email:, purchaser_id: nil).find_each do |past_purchase|
      attach(past_purchase, user)
    rescue => e
      failure ||= e
    end
    raise failure if failure
  end

  private
    # Keep processing after a row fails, then re-raise so Sidekiq retries
    # purchases that remain unlinked. A `false` result is a deliberate skip.
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
