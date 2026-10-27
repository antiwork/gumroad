# frozen_string_literal: true

require "spec_helper"

describe ResourceSubscription::TestEvent do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  def test_event_for(resource_name)
    described_class.new(create(:resource_subscription, user: seller, resource_name:))
  end

  describe "#payload" do
    ResourceSubscription::VALID_RESOURCE_NAMES.each do |resource_name|
      it "synthesizes a #{resource_name} payload marked as a test when the seller has no matching event" do
        test_event = test_event_for(resource_name)

        expect(test_event.payload).to include(resource_name:, test: true)
        expect(test_event.from_last_event?).to be(false)
      end
    end

    it "flags refund and dispute samples the way real events do" do
      expect(test_event_for("refund").payload).to include(refunded: true, disputed: false, dispute_won: false)
      expect(test_event_for("dispute").payload).to include(refunded: false, disputed: true, dispute_won: false)
      expect(test_event_for("dispute_won").payload).to include(disputed: true, dispute_won: true)
    end

    it "includes the documented subscription_updated fields in the sample" do
      expect(test_event_for("subscription_updated").payload.keys).to include(:type, :effective_as_of, :old_plan, :new_plan)
    end

    it "uses the seller's last sale, including test purchases" do
      create(:purchase, link: product, seller:)
      latest = create(:test_purchase, link: product, seller:, purchaser: seller)
      test_event = test_event_for("sale")

      expect(test_event.payload).to include(sale_id: ObfuscateIds.encrypt(latest.id), resource_name: "sale", test: true)
      expect(test_event.from_last_event?).to be(true)
    end

    it "ignores another seller's refunds" do
      create(:refunded_purchase, link: create(:product))

      expect(test_event_for("refund").from_last_event?).to be(false)
    end

    it "uses the last won dispute's sale for dispute_won" do
      purchase = create(:purchase, link: product, seller:, chargeback_date: 1.day.ago, chargeback_reversed: true)
      create(:dispute, purchase:, state: :won, won_at: Time.current)

      test_event = test_event_for("dispute_won")

      expect(test_event.payload).to include(sale_id: ObfuscateIds.encrypt(purchase.id), dispute_won: true, test: true)
      expect(test_event.from_last_event?).to be(true)
    end

    it "uses the seller's last cancelled subscription for cancellation" do
      purchase = create(:membership_purchase, link: create(:membership_product, user: seller), seller:)
      purchase.subscription.update!(cancelled_at: 1.day.ago, user_requested_cancellation_at: 1.day.ago)

      test_event = test_event_for("cancellation")

      expect(test_event.payload).to include(subscription_id: purchase.subscription.external_id, cancelled: true, resource_name: "cancellation", test: true)
      expect(test_event.from_last_event?).to be(true)
    end
  end

  describe "#deliver" do
    it "enqueues one delivery to the subscription's own post_url and moves no money" do
      purchase = create(:refunded_purchase, link: product, seller:)
      resource_subscription = create(:resource_subscription, user: seller, resource_name: "refund", post_url: "https://example.com/hook", content_type: Mime[:json].to_s)

      expect do
        described_class.new(resource_subscription).deliver
      end.to not_change { Refund.count }.and not_change { BalanceTransaction.count }.and not_change { purchase.reload.attributes }

      expect(PostToIndividualPingEndpointWorker.jobs.size).to eq(1)
      expect(PostToIndividualPingEndpointWorker.jobs.first["args"]).to match(["https://example.com/hook", hash_including("test" => true, "resource_name" => "refund"), Mime[:json].to_s, seller.id])
    end
  end
end
