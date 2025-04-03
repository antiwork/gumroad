# frozen_string_literal: true

class SendPaymentReminderWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  def perform
    User.payment_reminder_risk_state.announcement_notification_enabled
        .where(payment_address: nil).holding_balance_more_than(1000)
        .find_each do |user|
      ContactingCreatorMailer.remind(user.id).deliver_later(queue: "low") if user.active_bank_account.nil? && user.stripe_connect_account.blank? && !user.has_paypal_account_connected? && user.form_email.present?
    end
  end
end
