# frozen_string_literal: true

require "test_helper"

class ReviewReminderJobTest < ActiveSupport::TestCase
  self.described_class = ReviewReminderJob



  context_ ReviewReminderJob do
    let(:purchase) { create(:purchase) }

  test "sends an email" do
      expect do
        described_class.new.perform(purchase.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder).with(purchase.id)
    end

  context_ "purchase has a review" do
      before { purchase.product_review = create(:product_review) }

  test "does not send an email" do
        expect do
          described_class.new.perform(purchase.id)
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
      end
    end

  context_ "purchase was refunded" do
      before { purchase.update!(stripe_refunded: true) }

  test "does not send an email" do
        expect do
          described_class.new.perform(purchase.id)
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
      end
    end

  context_ "purchase was charged back" do
      before { purchase.update!(chargeback_date: Time.current) }

  test "does not send an email" do
        expect do
          described_class.new.perform(purchase.id)
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
      end
    end

  context_ "purchase was chargeback reversed" do
      before { purchase.update!(chargeback_date: Time.current, chargeback_reversed: true) }

  test "sends an email" do
        expect do
          described_class.new.perform(purchase.id)
        end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder).with(purchase.id)
      end
    end

  context_ "purchaser opted out of review reminders" do
      before { purchase.update!(purchaser: create(:user, opted_out_of_review_reminders: true)) }

  test "does not send an email" do
        expect do
          described_class.new.perform(purchase.id)
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
      end
    end

  test "does not send duplicate emails" do
      expect do
        described_class.new.perform(purchase.id)
        described_class.new.perform(purchase.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder).with(purchase.id).once
    end
  end
end
