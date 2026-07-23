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

  context "when a gift recipient is among multiple eligible purchases" do
    let(:product) { create(:product) }
    let(:gift) { create(:gift, link: product) }
    let(:gifter_purchase) { create(:purchase, :gift_sender, link: product, gift_given: gift) }
    let!(:giftee_purchase) { create(:purchase, :gift_receiver, link: product, gift_received: gift) }

    before do
      allow(order).to receive(:purchases).and_return([gifter_purchase, eligible_purchase])
    end

    it "sends a per-purchase reminder to each eligible purchase instead of the order-level email" do
      expect do
        described_class.new.perform(order.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
        .with(giftee_purchase.id)
        .on_queue(:low)
        .once
        .and have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
        .with(eligible_purchase.id)
        .on_queue(:low)
        .once
    end

    it "sends only the never-enqueued reminders when retrying after a partial enqueue" do
      # Simulates a Sidekiq retry after the process died partway through the
      # per-purchase loop: the gift recipient's reminder was already recorded,
      # but the other purchase was never attempted. Because each purchase
      # carries its own uniqueness record, the retry sends the remaining
      # reminder instead of skipping the whole order.
      SentEmailInfo.set_key!(
        SentEmailInfo.mailer_key_digest("CustomerLowPriorityMailer", "purchase_review_reminder", giftee_purchase.id)
      )

      expect do
        described_class.new.perform(order.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
        .with(eligible_purchase.id)
        .on_queue(:low)
        .once

      expect do
        described_class.new.perform(order.id)
      end.not_to have_enqueued_mail(CustomerLowPriorityMailer)
    end

    it "does not record a uniqueness key when an enqueue raises, so the retry re-sends" do
      # Simulates deliver_later itself failing (e.g. Redis unavailable). The
      # uniqueness key is only recorded after a successful enqueue, so a failed
      # enqueue leaves no key behind and the Sidekiq retry re-attempts the
      # recipient instead of permanently skipping them.
      call_count = 0
      allow(CustomerLowPriorityMailer).to receive(:purchase_review_reminder).and_wrap_original do |original, *args|
        call_count += 1
        raise "enqueue failed" if call_count == 1
        original.call(*args)
      end

      expect do
        described_class.new.perform(order.id)
      end.to raise_error("enqueue failed")

      # The retry sends reminders for BOTH purchases: the failed one was not
      # left with a stranded key, and the other was never attempted.
      expect do
        described_class.new.perform(order.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
        .with(giftee_purchase.id)
        .on_queue(:low)
        .once
        .and have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
        .with(eligible_purchase.id)
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
    # The order for a gifted bundle contains only the gift-SENDER purchase, which
    # can never leave a review — the recipient's linked purchase owns the review.
    # The job resolves the sender purchase to the recipient's purchase and sends
    # the reminder there.
    let(:bundle) { create(:product, :bundle) }
    let(:gift) { create(:gift, link: bundle) }
    let(:gifter_purchase) { create(:purchase, :gift_sender, link: bundle, gift_given: gift, is_bundle_purchase: true) }
    let!(:giftee_purchase) { create(:purchase, :gift_receiver, link: bundle, gift_received: gift, is_bundle_purchase: true) }
    let(:gifted_bundle_order) { create(:order, purchases: [gifter_purchase]) }

    before do
      allow(Order).to receive(:find).and_call_original
    end

    it "sends a single review reminder to the gift recipient's purchase" do
      expect(gifter_purchase.eligible_for_review_reminder?).to eq(false)
      expect(giftee_purchase.eligible_for_review_reminder?).to eq(true)

      expect do
        described_class.new.perform(gifted_bundle_order.id)
        described_class.new.perform(gifted_bundle_order.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
        .with(giftee_purchase.id)
        .on_queue(:low)
        .once
    end
  end

  context "gifted regular product order" do
    let(:product) { create(:product) }
    let(:gift) { create(:gift, link: product) }
    let(:gifter_purchase) { create(:purchase, :gift_sender, link: product, gift_given: gift) }
    let!(:giftee_purchase) { create(:purchase, :gift_receiver, link: product, gift_received: gift) }
    let(:gifted_order) { create(:order, purchases: [gifter_purchase]) }

    before do
      allow(Order).to receive(:find).and_call_original
    end

    it "sends a single review reminder to the gift recipient's purchase" do
      expect do
        described_class.new.perform(gifted_order.id)
        described_class.new.perform(gifted_order.id)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
        .with(giftee_purchase.id)
        .on_queue(:low)
        .once
    end

    context "when the gift recipient opted out of review reminders" do
      before do
        giftee_purchase.update!(purchaser: create(:user, opted_out_of_review_reminders: true))
      end

      it "does not send a reminder" do
        expect do
          described_class.new.perform(gifted_order.id)
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
      end
    end

    context "when the seller disabled review reminders" do
      before do
        product.user.update!(disable_review_reminders: true)
      end

      it "does not send a reminder" do
        expect do
          described_class.new.perform(gifted_order.id)
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :purchase_review_reminder)
      end
    end
  end
end
