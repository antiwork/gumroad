# frozen_string_literal: true

class ExpiringCreditCardMessageWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  # Selects all the credit cards that expire next month and notifies the customers to update them.
  # There are 2 types of emails that we send to users:
  # - emails that specify the membership assigned
  # - a general email that mentions the last purchase
  def perform
    cutoff_date = Date.today.at_beginning_of_month.next_month
    CreditCard.includes(:users).where(expiry_month: cutoff_date.month, expiry_year: cutoff_date.year).find_each do |credit_card|
      credit_card.users.each do |user|
        next unless user.form_email.present?

        user.subscriptions.active_without_pending_cancel.where(credit_card_id: credit_card.id).each do |subscription|
          CustomerLowPriorityMailer.credit_card_expiring_membership(subscription.id).deliver_later(queue: "low")
        end
      end
    end
  end
end
