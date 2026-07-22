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

  context "bundle order" do
    # A bundle checkout creates one order-level purchase for the bundle plus a child
    # purchase per product inside it. Only the bundle purchase belongs to the order,
    # so the buyer gets exactly one reminder pointing at the bundle review — not one
    # reminder per bundled product.
    let(:bundle_purchase) { create(:purchase, link: create(:product, :bundle)) }
    let(:bundle_order) { create(:order, purchases: [bundle_purchase]) }

    before do
      # The top-level before stubs Order.find for the other order; restore real
      # lookups here so the job loads the bundle order from the database.
      allow(Order).to receive(:find).and_call_original
      bundle_purchase.create_artifacts_and_send_receipt!
    end

    it "enqueues a single purchase review reminder for the bundle purchase" do
      expect(bundle_purchase.eligible_for_review_reminder?).to eq(true)

      expect do
        described_class.new.perform(bundle_order.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
        .with(bundle_purchase.id)
        .on_queue(:low)
        .once
    end
  end

  context "gifted bundle order" do
    # The order for a gifted bundle contains the gift-SENDER purchase, which can
    # never leave a review (the giftee's purchase owns the review) — so no reminder
    # should go out for it.
    let(:bundle) { create(:product, :bundle) }
    let(:gift) { create(:gift, link: bundle) }
    let(:gifter_purchase) { create(:purchase, :gift_sender, link: bundle, gift_given: gift, is_bundle_purchase: true) }
    let(:gifted_bundle_order) { create(:order, purchases: [gifter_purchase]) }

    before do
      allow(Order).to receive(:find).and_call_original
      create(:purchase, :gift_receiver, link: bundle, is_gift_receiver_purchase: true, gift_received: gift, purchase_state: "gift_receiver_purchase_successful", is_bundle_purchase: true)
    end

    it "does not send a review reminder to the gifter" do
      expect(gifter_purchase.eligible_for_review_reminder?).to eq(false)

      expect do
        described_class.new.perform(gifted_bundle_order.id)
      end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
    end
  end
end
