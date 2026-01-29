# frozen_string_literal: true

class UpdatePurchaseEmailToMatchAccountWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id, old_email = nil)
    user = User.find(user_id)

    user.purchases.find_each do |purchase|
      purchase.update!(email: user.email)
    end

    if old_email.present?
      gift_receiver_flag = Purchase.flag_mapping["flags"][:is_gift_receiver_purchase]
      Purchase.where(purchaser_id: nil, email: old_email).where("flags & ? != 0", gift_receiver_flag).find_each do |purchase|
        purchase.update!(email: user.email)
      end
    end
  end
end
