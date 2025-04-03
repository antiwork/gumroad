# frozen_string_literal: true

require "spec_helper"

describe OrderReviewReminderJob do
  let(:order) { create(:order) }
  let(:eligible_purchase) { create(:purchase, order: order) }
  let(:ineligible_purchase) { create(:purchase, order: order) }

  before do
    allow(Order).to receive(:find).with(order.id).and_return(order)
    allow(eligible_purchase).to receive(:eligible_for_review_reminder?).and_return(true)
    allow(ineligible_purchase).to receive(:eligible_for_review_reminder?).and_return(false)
  end

  context "when there are no eligible purchases" do
    before do
      allow(order).to receive(:purchases).and_return([ineligible_purchase])
    end

    it "does not enqueue any emails" do
      expect do
        described_class.new.perform(order.id)
      end.not_to have_enqueued_mail(CustomerLowPriorityMailer)
    end
  end

  context "when there is one eligible purchase" do
    before do
      allow(order).to receive(:purchases).and_return([eligible_purchase, ineligible_purchase])
    end

    it "enqueues a single purchase review reminder once" do
      expect do
        described_class.new.perform(order.id)
        described_class.new.perform(order.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
        .with(eligible_purchase.id)
        .on_queue(:low)
        .once
    end
  end

  context "when there are multiple eligible purchases" do
    let(:another_eligible_purchase) { create(:purchase, order: order) }

    before do
      allow(order).to receive(:purchases).and_return([eligible_purchase, another_eligible_purchase])
      allow(another_eligible_purchase).to receive(:eligible_for_review_reminder?).and_return(true)
    end

    it "enqueues an order review reminder once" do
      expect do
        described_class.new.perform(order.id)
        described_class.new.perform(order.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :order_review_reminder)
        .with(order.id)
        .on_queue(:low)
        .once
    end
  end
end
