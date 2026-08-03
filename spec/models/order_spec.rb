# frozen_string_literal: true

require "spec_helper"

describe Order do
  let(:product) { create(:product) }
  let(:purchase) { create(:purchase, link: product) }
  let(:order) { create(:order, purchases: [purchase]) }

  describe "#receipt_for_gift_receiver?" do
    context "when the purchase is not for a gift receiver" do
      it "returns false" do
        expect(order.receipt_for_gift_receiver?).to be(false)
      end
    end

    context "when the purchase is for a gift receiver" do
      let(:gift) { create(:gift) }
      let!(:gifter_purchase) { create(:purchase, link: gift.link, gift_given: gift, is_gift_sender_purchase: true) }
      let(:purchase) { create(:purchase, link: gift.link, gift_received: gift, is_gift_receiver_purchase: true) }

      it "returns true" do
        expect(order.receipt_for_gift_receiver?).to be(true)
      end
    end

    context "when there are no successful purchases" do
      let(:purchase) { create(:failed_purchase) }

      it "returns false" do
        expect(order.receipt_for_gift_receiver?).to be(false)
      end
    end

    context "when there are multiple purchases per order" do
      let(:other_purchase) { create(:purchase) }

      before do
        order.purchases << other_purchase
      end

      it "raises" do
        expect { order.receipt_for_gift_receiver? }.to raise_error(NotImplementedError).with_message("Not supported for multi-item orders")
      end
    end
  end

  describe "#receipt_for_gift_sender?" do
    context "when the purchase is not for a gift sender" do
      it "returns false" do
        expect(order.receipt_for_gift_sender?).to be(false)
      end
    end

    context "when the purchase is for a gift sender" do
      let(:gift) { create(:gift) }

      before do
        purchase.update!(is_gift_sender_purchase: true, gift_given: gift)
      end

      it "returns true" do
        expect(order.receipt_for_gift_sender?).to be(true)
      end
    end

    context "when there are no successful purchases" do
      let(:purchase) { create(:failed_purchase) }

      it "returns false" do
        expect(order.receipt_for_gift_sender?).to be(false)
      end
    end

    context "when there are multiple purchases per order" do
      let(:other_purchase) { create(:purchase) }

      before do
        order.purchases << other_purchase
      end

      it "raises" do
        expect { order.receipt_for_gift_sender? }.to raise_error(NotImplementedError).with_message("Not supported for multi-item orders")
      end
    end
  end

  describe "#email" do
    it "returns the email of the purchase" do
      expect(order.email).to eq(purchase.email)
    end

    context "when there are no successful purchases" do
      let(:purchase) { create(:failed_purchase) }

      it "returns nil instead of raising" do
        expect(order.email).to be_nil
      end
    end
  end

  describe "#locale" do
    it "returns the locale of the purchase" do
      expect(order.locale).to eq(purchase.locale)
    end

    context "when there are no successful purchases" do
      let(:purchase) { create(:failed_purchase) }

      it "returns nil instead of raising" do
        expect(order.locale).to be_nil
      end
    end
  end

  describe "#test?" do
    context "when the purchase is not a test purchase" do
      it "returns false" do
        expect(order.test?).to eq(false)
      end
    end

    context "when there are no successful purchases" do
      let(:purchase) { create(:failed_purchase) }

      it "returns false instead of raising" do
        expect(order.test?).to eq(false)
      end
    end

    context "when the purchase is a test purchase" do
      before do
        allow_any_instance_of(Purchase).to receive(:is_test_purchase?).and_return(true)
      end

      it "returns true" do
        expect(order.test?).to eq(true)
      end
    end
  end

  describe "#purchase_with_payment_as_orderable" do
    let(:purchase) { create(:failed_purchase) }
    let(:free_purchase) { create(:free_purchase) }

    before do
      order.purchases << free_purchase
    end

    context "without a successful paid purchase" do
      it "returns the free purchase" do
        expect(order.send(:purchase_with_payment_as_orderable)).to eq(free_purchase)
      end
    end

    context "with a successful paid purchase" do
      let(:paid_purchase) { create(:purchase) }

      before do
        order.purchases << paid_purchase
      end

      it "returns the paid purchase" do
        expect(order.send(:purchase_with_payment_as_orderable)).to eq(paid_purchase)
      end
    end
  end

  describe "Purchase attributes" do
    let(:purchase) { create(:failed_purchase) }
    let(:free_purchase) { create(:free_purchase) }
    let(:paid_purchase) { create(:purchase) }
    let(:physical_product) { create(:product, :is_physical) }
    let(:physical_purchase) { create(:physical_purchase, link: physical_product) }

    before do
      order.purchases << free_purchase
      order.purchases << paid_purchase
      order.purchases << physical_purchase
    end

    it "returns the correct purchase attributes" do
      expect(order.send(:purchase_as_orderable)).to eq(free_purchase)
      expect(order.send(:purchase_with_payment_as_orderable)).to eq(paid_purchase)

      expect(order.card_type).to eq(paid_purchase.card_type)
      expect(order.card_visual).to eq(paid_purchase.card_visual)
    end
  end

  describe "#purchase_as_orderable" do
    let(:purchase) { create(:failed_purchase) }
    let(:test_purchase) { create(:test_purchase) }
    let(:paid_purchase) { create(:purchase) }

    before do
      order.purchases << test_purchase
      order.purchases << paid_purchase
    end

    it "returns first successful purchase" do
      expect(order.send(:purchase_as_orderable)).to eq(test_purchase)
    end
  end

  describe "#send_charge_receipts", :vcr do
    let(:order) { create(:order) }
    let(:product_one) { create(:product) }
    let(:purchase_one) { create(:purchase, link: product_one) }
    let!(:charge_one) { create(:charge, order:, purchases: [purchase_one]) }
    let!(:charge_two) { create(:charge, order:, purchases: [create(:purchase)]) }
    let!(:failed_charge) { create(:charge, order:, purchases: [create(:failed_purchase)]) }

    it "sends charge receipts" do
      order.send_charge_receipts
      expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge_one.id).on("critical")
      expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge_two.id).on("critical")
      expect(SendChargeReceiptJob).not_to have_enqueued_sidekiq_job(failed_charge.id)
    end

    context "when a product has stampable PDFs" do
      before do
        product_one.product_files << create(:readable_document, pdf_stamp_enabled: true)
        purchase_one.create_url_redirect!
      end

      it "enqueues the job on the default job queue" do
        order.send_charge_receipts
        expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge_one.id).on("default")
        expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge_two.id).on("critical")
        expect(SendChargeReceiptJob).not_to have_enqueued_sidekiq_job(failed_charge.id)
      end
    end
  end

  describe "#successful_charges", :vcr do
    let(:order) { create(:order) }
    let!(:charge_one) { create(:charge, order:, purchases: [create(:purchase)]) }
    let!(:charge_two) { create(:charge, order:, purchases: [create(:purchase)]) }
    let!(:failed_charge) { create(:charge, order:, purchases: [create(:failed_purchase)]) }

    it "returns the successful charges" do
      expect(order.successful_charges).to eq([charge_one, charge_two])
    end
  end

  describe "#schedule_review_reminder!" do
    let(:order) { create(:order) }
    let(:purchase) { create(:purchase) }
    let(:cart) { create(:cart) }

    before do
      order.cart = cart
    end

    context "when there is a successful and eligible purchase" do
      it "schedules a review reminder" do
        expect(OrderReviewReminderJob).to receive(:perform_in).with(ProductReview::REVIEW_REMINDER_DELAY, order.id)
        order.purchases << purchase
        order.save
      end

      context "when review_reminder_scheduled_at is present" do
        before { order.update(review_reminder_scheduled_at: Time.current) }

        it "does not schedule a review reminder" do
          expect(OrderReviewReminderJob).not_to receive(:perform_in)
          order.purchases << purchase
          order.save
        end
      end

      context "when purchases require shipping" do
        let(:physical_product) { create(:product, :is_physical) }
        let(:physical_purchase) { create(:physical_purchase, link: physical_product) }

        it "schedules a reminder with REVIEW_REMINDER_PHYSICAL_DELAY" do
          expect(OrderReviewReminderJob).to receive(:perform_in).with(ProductReview::REVIEW_REMINDER_PHYSICAL_DELAY, order.id)
          order.purchases << physical_purchase
          order.save
        end
      end
    end

    context "when there are no successful purchases" do
      let(:purchase) { create(:purchase_in_progress) }
      it "does not schedule a review reminder" do
        expect(OrderReviewReminderJob).not_to receive(:perform_in)
        order.purchases << purchase
        order.save
      end
    end

    context "when there are successful purchases but none are eligible" do
      let(:ineligible_purchase) { create(:purchase, :with_review) }

      it "does not schedule a review reminder" do
        expect(OrderReviewReminderJob).not_to receive(:perform_in)
        order.purchases << ineligible_purchase
        order.save
      end
    end

    context "when the order contains only a gift-sender purchase" do
      # A gift order's checkout line item is the sender's purchase, which can never
      # be reviewed — but the recipient's linked purchase can, so the reminder is
      # still scheduled (the job then resolves it to the recipient's purchase).
      let(:product) { create(:product) }
      let(:gift) { create(:gift, link: product) }
      let(:gifter_purchase) { create(:purchase, :gift_sender, link: product, gift_given: gift) }
      let!(:giftee_purchase) { create(:purchase, :gift_receiver, link: product, gift_received: gift) }

      it "schedules a review reminder" do
        expect(OrderReviewReminderJob).to receive(:perform_in).with(ProductReview::REVIEW_REMINDER_DELAY, order.id)
        order.purchases << gifter_purchase
        order.save
      end
    end
  end
  describe "#record_charge_outcome!" do
    let(:seller_1) { create(:user) }
    let(:seller_2) { create(:user) }
    let(:product_1) { create(:product, user: seller_1) }
    let(:product_2) { create(:product, user: seller_2) }
    let(:order) { create(:order) }

    # The write lives in RecordOrderChargeOutcomeJob, enqueued after the purchase's transaction
    # commits. Draining it is what a real settle does.
    def settle
      yield
      RecordOrderChargeOutcomeJob.drain
    end

    context "when one seller group succeeded and another failed" do
      it "flags the order partially_successful" do
        succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
        failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
        order.purchases << succeeded << failed

        settle { succeeded.update_balance_and_mark_successful! }
        expect(order.reload).not_to be_partially_successful

        settle { Purchase::MarkFailedService.new(failed).perform }

        expect(order.reload).to be_partially_successful
      end
    end

    context "when every line item succeeded" do
      it "leaves the order unflagged" do
        one = create(:purchase_in_progress, link: product_1, seller: seller_1)
        two = create(:purchase_in_progress, link: product_2, seller: seller_2)
        order.purchases << one << two

        settle do
          one.update_balance_and_mark_successful!
          two.update_balance_and_mark_successful!
        end

        expect(order.reload).not_to be_partially_successful
      end
    end

    context "when every line item failed" do
      it "leaves the order unflagged" do
        one = create(:purchase_in_progress, link: product_1, seller: seller_1)
        two = create(:purchase_in_progress, link: product_2, seller: seller_2)
        order.purchases << one << two

        settle do
          Purchase::MarkFailedService.new(one).perform
          Purchase::MarkFailedService.new(two).perform
        end

        expect(order.reload).not_to be_partially_successful
      end
    end

    # An order mid-SCA is undecided, not partial: `in_progress` must count as neither side of the
    # AND. These two pin each half of it - drop either `exists?` call and one of them reddens.
    context "when a line item succeeded and its sibling is still in progress" do
      it "leaves the order unflagged" do
        succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
        create(:purchase_in_progress, link: product_2, seller: seller_2).tap { order.purchases << _1 }
        order.purchases << succeeded

        settle { succeeded.update_balance_and_mark_successful! }

        expect(order.reload).not_to be_partially_successful
      end
    end

    context "when a line item failed and its sibling is still in progress" do
      it "leaves the order unflagged" do
        failed = create(:purchase_in_progress, link: product_1, seller: seller_1)
        create(:purchase_in_progress, link: product_2, seller: seller_2).tap { order.purchases << _1 }
        order.purchases << failed

        settle { Purchase::MarkFailedService.new(failed).perform }

        expect(order.reload).not_to be_partially_successful
      end
    end

    context "when a line item settles long after the charge loop returned" do
      it "flags the order on that late transition" do
        succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
        late_item = create(:purchase_in_progress, link: product_2, seller: seller_2)
        order.purchases << succeeded << late_item

        settle { succeeded.update_balance_and_mark_successful! }
        expect(order.reload).not_to be_partially_successful

        # SCA confirmation, FailAbandonedPurchaseWorker and the processor-sync recovery paths all
        # resolve line items after the charge loop has returned.
        settle { Purchase::MarkFailedService.new(late_item).perform }

        expect(order.reload).to be_partially_successful
      end
    end

    context "when the outcome is already recorded" do
      it "does not write the order row again" do
        succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
        failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
        order.purchases << succeeded << failed
        settle { succeeded.update_balance_and_mark_successful! }
        settle { Purchase::MarkFailedService.new(failed).perform }
        expect(order.reload).to be_partially_successful

        expect do
          order.record_charge_outcome!
        end.not_to change { order.reload.updated_at }
      end
    end

    context "when the only successful line item is a test purchase" do
      # A seller testing their own product is not a buyer half-served, so a test purchase beside a
      # real failure must not mark the order partial.
      it "leaves the order unflagged" do
        test_item = create(:test_purchase, link: product_1)
        failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
        order.purchases << test_item << failed

        settle { Purchase::MarkFailedService.new(failed).perform }

        expect(order.reload).not_to be_partially_successful
      end
    end

    context "when the flag is written concurrently with another bit on the same order" do
      # `flags` is a shared bitfield, so the write must be a bitwise OR rather than a
      # read-modify-write of a stale in-memory value.
      it "does not clobber a bit set after this order was loaded" do
        succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
        failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
        order.purchases << succeeded << failed
        settle { succeeded.update_balance_and_mark_successful! }

        stale = Order.find(order.id)
        Order.where(id: order.id).update_all("flags = flags | 1")

        settle { Purchase::MarkFailedService.new(failed).perform }
        stale.record_charge_outcome!

        order.reload
        expect(order).to be_partially_successful
        expect(order.flags & 1).to eq(1)
      end
    end

    context "when the failing line item is a declined preorder authorization" do
      # `preorder_authorization_failed` is its own terminal checkout failure, not `failed`, so a
      # scope keyed on `failed` alone leaves this order unflagged.
      it "flags the order partially_successful" do
        succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
        preorder = create(:purchase_in_progress, link: product_2, seller: seller_2, is_preorder_authorization: true)
        order.purchases << succeeded << preorder

        settle { succeeded.update_balance_and_mark_successful! }
        expect(order.reload).not_to be_partially_successful

        settle { preorder.mark_preorder_authorization_failed! }

        expect(order.reload).to be_partially_successful
      end
    end

    context "when the failing line item is an uncreatable giftee purchase" do
      it "flags the order partially_successful" do
        succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
        giftee = create(:purchase_in_progress, link: product_2, seller: seller_2, is_gift_receiver_purchase: true)
        order.purchases << succeeded << giftee

        settle { succeeded.update_balance_and_mark_successful! }
        settle { giftee.mark_gift_receiver_purchase_failed! }

        expect(order.reload).to be_partially_successful
      end
    end

    context "when the sibling transitions have not committed yet" do
      # `after_transition` runs inside the purchase's own transaction, so two line items settling
      # concurrently each read the other as still in progress and both skip the write. The
      # reconciliation therefore has to happen after commit, from the job.
      it "writes nothing mid-transaction and reconciles once the job runs" do
        succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
        failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
        order.purchases << succeeded << failed
        RecordOrderChargeOutcomeJob.jobs.clear

        succeeded.update_balance_and_mark_successful!
        Purchase::MarkFailedService.new(failed).perform
        expect(order.reload).not_to be_partially_successful

        expect(RecordOrderChargeOutcomeJob.jobs.map { _1["args"] }).to include([order.id])
        RecordOrderChargeOutcomeJob.drain

        expect(order.reload).to be_partially_successful
      end
    end

    context "when an attached line item transitions to a state the predicate ignores" do
      # A preorder concluding cannot change the answer — its authorization already counted as the
      # success — so that transition must not enqueue a reconciliation.
      it "enqueues no reconciliation" do
        preorder = create(:purchase_in_progress, link: product_1, seller: seller_1, is_preorder_authorization: true)
        order.purchases << preorder
        settle { preorder.mark_preorder_authorization_successful! }
        RecordOrderChargeOutcomeJob.jobs.clear

        preorder.mark_preorder_concluded_successfully!

        expect(RecordOrderChargeOutcomeJob.jobs).to be_empty
      end
    end

    context "when the same order is reconciled twice" do
      it "is idempotent" do
        succeeded = create(:purchase_in_progress, link: product_1, seller: seller_1)
        failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
        order.purchases << succeeded << failed
        settle { succeeded.update_balance_and_mark_successful! }
        settle { Purchase::MarkFailedService.new(failed).perform }

        expect do
          RecordOrderChargeOutcomeJob.new.perform(order.id)
          RecordOrderChargeOutcomeJob.new.perform(order.id)
        end.not_to change { order.reload.updated_at }
        expect(order.reload).to be_partially_successful
      end
    end
    context "when the flag is already set and the current states no longer justify it" do
      # Set-only. Partial success is a fact about the checkout, not a current-state query, so no
      # later recompute may clear a flag that was correct when written — whatever moved the line
      # items since. This pins the write direction itself, independent of which states count.
      it "never clears the flag" do
        failed = create(:purchase_in_progress, link: product_1, seller: seller_1)
        order.purchases << failed
        settle { Purchase::MarkFailedService.new(failed).perform }
        Order.where(id: order.id).update_all("flags = flags | #{Order.flag_mapping['flags'][:partially_successful]}")
        expect(order.reload).to be_partially_successful

        Order.find(order.id).record_charge_outcome!

        expect(order.reload).to be_partially_successful
      end
    end

    context "when a preorder concludes after the order was already flagged" do
      # The predicate is not monotone: concluding takes the line item out of ALL_SUCCESS_STATES, so
      # a recompute-and-overwrite write clears a flag that was correct. The write is set-only.
      it "keeps the flag" do
        preorder = create(:purchase_in_progress, link: product_1, seller: seller_1, is_preorder_authorization: true)
        failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
        order.purchases << preorder << failed

        settle { preorder.mark_preorder_authorization_successful! }
        settle { Purchase::MarkFailedService.new(failed).perform }
        expect(order.reload).to be_partially_successful

        preorder.mark_preorder_concluded_unsuccessfully!
        RecordOrderChargeOutcomeJob.new.perform(order.id)

        expect(order.reload).to be_partially_successful
      end
    end

    context "when the preorder concludes before its sibling fails" do
      # Ordering must not decide the outcome. A concluded preorder is reachable only from
      # `preorder_authorization_successful`, so it is still evidence the checkout served this item.
      it "flags the order partially_successful" do
        preorder = create(:purchase_in_progress, link: product_1, seller: seller_1, is_preorder_authorization: true)
        failed = create(:purchase_in_progress, link: product_2, seller: seller_2)
        order.purchases << preorder << failed

        settle { preorder.mark_preorder_authorization_successful! }
        preorder.mark_preorder_concluded_unsuccessfully!
        expect(order.reload).not_to be_partially_successful

        settle { Purchase::MarkFailedService.new(failed).perform }

        expect(order.reload).to be_partially_successful
      end
    end
  end
end
