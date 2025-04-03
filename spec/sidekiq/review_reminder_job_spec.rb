# frozen_string_literal: true

require "spec_helper"

describe ReviewReminderJob do
  let(:purchase) { create(:purchase) }

  it "sends an email" do
    expect do
      described_class.new.perform(purchase.id)
    end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder).with(purchase.id)
  end

  context "purchase has a review" do
    before { purchase.product_review = create(:product_review) }

    it "does not send an email" do
      expect do
        described_class.new.perform(purchase.id)
      end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
    end
  end

  context "purchase was refunded" do
    before { purchase.update!(stripe_refunded: true) }

    it "does not send an email" do
      expect do
        described_class.new.perform(purchase.id)
      end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
    end
  end

  context "purchase was charged back" do
    before { purchase.update!(chargeback_date: Time.current) }

    it "does not send an email" do
      expect do
        described_class.new.perform(purchase.id)
      end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
    end
  end

  context "purchase was chargeback reversed" do
    before { purchase.update!(chargeback_date: Time.current, chargeback_reversed: true) }

    it "sends an email" do
      expect do
        described_class.new.perform(purchase.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder).with(purchase.id)
    end
  end

  context "purchaser opted out of review reminders" do
    before { purchase.update!(purchaser: create(:user, opted_out_of_review_reminders: true)) }

    it "does not send an email" do
      expect do
        described_class.new.perform(purchase.id)
      end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
    end
  end

  it "does not send duplicate emails" do
    expect do
      described_class.new.perform(purchase.id)
      described_class.new.perform(purchase.id)
    end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder).with(purchase.id).once
  end
end
