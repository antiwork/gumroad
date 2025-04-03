# frozen_string_literal: true

require "spec_helper"

describe BlockStripeSuspectedFraudulentPaymentsWorker do
  describe "#perform" do
    before do
      @payload = JSON.parse(file_fixture("helper_conversation_created.json").read)["payload"]
      admin = create(:admin_user)
      stub_const("GUMROAD_ADMIN_ID", admin.id)
    end

    it "parses payment records from Stripe emails" do
      records = described_class.new.send(:parse_payment_records_from_body, @payload["body"])
      expect(records.length).to eq(20)
      expect(records.first).to eq("ch_2LBu5J9e1RjUNIyY1Q3Kw06Q")
      expect(records.last).to eq("ch_2LBu5X9e1RjUNIyY1PerqPRf")
    end

    it "blocks the listed purchases, adds a note, and closes the ticket" do
      purchases = []
      charge_ids = ["ch_2LBu5J9e1RjUNIyY1Q3Kw06Q", "ch_2LBu5X9e1RjUNIyY1PerqPRf"]
      charge_ids.each do |charge_id|
        purchases << create(:purchase, stripe_transaction_id: charge_id, stripe_fingerprint: SecureRandom.hex, purchaser: create(:user))
        expect(purchases.last.buyer_blocked?).to eq(false)
        allow(ChargeProcessor).to receive(:refund!)
        .with(StripeChargeProcessor.charge_processor_id, charge_id, hash_including(is_for_fraud: true))
        .and_return(create(:refund, purchase: purchases.last))
      end

      expect_any_instance_of(Helper::Client).to receive(:add_note).with(conversation_id: @payload["conversation_id"], message: described_class::HELPER_NOTE_CONTENT)
      expect_any_instance_of(Helper::Client).to receive(:close_conversation).with(conversation_id: @payload["conversation_id"])

      described_class.new.perform(@payload["conversation_id"], @payload["email_from"], @payload["body"])
      purchases.each do |purchase|
        purchase.reload
        expect(purchase.buyer_blocked?).to eq(true)
        expect(purchase.is_buyer_blocked_by_admin?).to eq(true)
        expect(purchase.comments.where(content: "Buyer blocked by Helper webhook").count).to eq(1)
        expect(purchase.purchaser.comments.where(content: "Buyer blocked by Helper webhook").count).to eq(1)
      end
    end

    context "when email is not from Stripe" do
      it "does not trigger any processing" do
        expect_any_instance_of(Helper::Client).not_to receive(:add_note)
        expect_any_instance_of(Helper::Client).not_to receive(:close_conversation)
        described_class.new.perform(@payload["conversation_id"], "not_stripe@example.com", @payload["body"])
      end
    end

    context "when email body does not contain any transaction IDs" do
      it "does not trigger any processing" do
        expect_any_instance_of(Helper::Client).not_to receive(:add_note)
        expect_any_instance_of(Helper::Client).not_to receive(:close_conversation)
        described_class.new.perform(@payload["conversation_id"], @payload["email_from"], "Some body")
      end
    end

    context "when there is an error" do
      it "notifies Bugsnag" do
        expect(Bugsnag).to receive(:notify).exactly(:once)
        described_class.new.perform(@payload["conversation_id"], @payload["email_from"], nil)
      end
    end
  end
end
