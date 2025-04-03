# frozen_string_literal: true

class SellerUpdateWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(user_id)
    user = User.find(user_id)
    ContactingCreatorMailer.seller_update(user.id).deliver_later(queue: "critical") if user.form_email && user.announcement_notification_enabled &&
                                                              (user.last_weeks_sales > 0 || user.last_weeks_followers > 0)
  end
end
