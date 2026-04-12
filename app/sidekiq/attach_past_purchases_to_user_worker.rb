# frozen_string_literal: true

class AttachPastPurchasesToUserWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default

  def perform(user_id)
    user = User.find(user_id)
    return if user.email.blank?

    Purchase.where(email: user.email, purchaser_id: nil).find_each do |past_purchase|
      past_purchase.attach_to_user_and_card(user, nil, nil)
    end
  end
end
