# frozen_string_literal: true

require "test_helper"

class ExpiringCreditCardMessageWorkerTest < ActiveSupport::TestCase
  self.described_class = ExpiringCreditCardMessageWorker
  self.rspec_metadata = { vcr: true }



  context_ ExpiringCreditCardMessageWorker, :vcr do
    let(:cutoff_date) { Date.today.at_beginning_of_month.next_month }
    let(:expiring_cc_user) { create(:user, credit_card: create(:credit_card, expiry_month: cutoff_date.month, expiry_year: cutoff_date.year)) }
    let(:valid_cc_user) { create(:user, credit_card: create(:credit_card, expiry_month: cutoff_date.month, expiry_year: cutoff_date.year + 1)) }

  context_ "with subscription" do
      let!(:subscription) { create(:subscription, user: expiring_cc_user, credit_card_id: expiring_cc_user.credit_card_id) }

  test "does enqueue the correct users for expiring credit card messages" do
        expect do
          ExpiringCreditCardMessageWorker.new.perform
        end.to have_enqueued_mail(CustomerLowPriorityMailer, :credit_card_expiring_membership).with(subscription.id)
      end

  test "does not enqueue users with blank emails" do
        expect_any_instance_of(User).to receive(:form_email).at_least(1).times.and_return(nil)
        expect do
          ExpiringCreditCardMessageWorker.new.perform
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :credit_card_expiring_membership).with(subscription.id)
      end

  test "does enqueue twice the expiring credit card messages with multiple subscriptions" do
        create(:subscription, user: expiring_cc_user, credit_card_id: expiring_cc_user.credit_card_id)

        expect do
          ExpiringCreditCardMessageWorker.new.perform
        end.to have_enqueued_mail(CustomerLowPriorityMailer, :credit_card_expiring_membership).twice
      end

  context_ "when subscription is lapsed" do
  test "does not enqueue membership emails" do
          subscription = create(:subscription, user: expiring_cc_user, credit_card_id: expiring_cc_user.credit_card_id, cancelled_at: 1.day.ago)
          expect do
            ExpiringCreditCardMessageWorker.new.perform
          end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :credit_card_expiring_membership).with(subscription.id)
        end
      end

  context_ "when subscription is pending cancellation" do
  test "does not enqueue membership emails" do
          subscription = create(:subscription, user: expiring_cc_user, credit_card_id: expiring_cc_user.credit_card_id, cancelled_at: 1.day.from_now)
          expect do
            ExpiringCreditCardMessageWorker.new.perform
          end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :credit_card_expiring_membership).with(subscription.id)
        end
      end
    end
  end
end
