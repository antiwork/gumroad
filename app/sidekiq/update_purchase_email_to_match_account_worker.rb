# frozen_string_literal: true

class UpdatePurchaseEmailToMatchAccountWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    user = User.find(user_id)
    user.purchases.find_each do |purchase|
      purchase.update!(email: user.email)
    end
  end
end
