# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillPurchaseRefundPolicyMaxRefundPeriod do
  let(:service) { described_class.new }

  describe "#process" do
    let!(:purchase_refund_policy_1) do
      create(:purchase_refund_policy, title: "30-day money back guarantee", max_refund_period_in_days: nil)
    end
    let!(:purchase_refund_policy_2) do
      create(:purchase_refund_policy, title: "7-day money back guarantee", max_refund_period_in_days: nil)
    end
    let!(:purchase_refund_policy_3) do
      create(:purchase_refund_policy, title: "No refunds allowed", max_refund_period_in_days: nil)
    end
    let!(:purchase_refund_policy_already_set) do
      create(:purchase_refund_policy, title: "14-day money back guarantee", max_refund_period_in_days: 14)
    end

    before do
      described_class.reset_last_processed_id
    end

    it "updates max_refund_period_in_days for policies with nil values" do
      expect { service.process }.to change { purchase_refund_policy_1.reload.max_refund_period_in_days }.from(nil).to(30)
        .and change { purchase_refund_policy_2.reload.max_refund_period_in_days }.from(nil).to(7)
        .and change { purchase_refund_policy_3.reload.max_refund_period_in_days }.from(nil).to(0)
    end

    it "does not update policies that already have max_refund_period_in_days set" do
      expect { service.process }.not_to change { purchase_refund_policy_already_set.reload.max_refund_period_in_days }
    end

    context "when title doesn't match any known pattern" do
      let!(:purchase_refund_policy_unknown) do
        create(:purchase_refund_policy, title: "Custom refund policy", max_refund_period_in_days: nil)
      end

      it "defaults to 30 days" do
        expect { service.process }.to change { purchase_refund_policy_unknown.reload.max_refund_period_in_days }.from(nil).to(30)
      end
    end
  end

  describe "#determine_max_refund_period_from_title" do
    it "returns correct days for known titles" do
      expect(service.send(:determine_max_refund_period_from_title, "No refunds allowed")).to eq(0)
      expect(service.send(:determine_max_refund_period_from_title, "7-day money back guarantee")).to eq(7)
      expect(service.send(:determine_max_refund_period_from_title, "14-day money back guarantee")).to eq(14)
      expect(service.send(:determine_max_refund_period_from_title, "30-day money back guarantee")).to eq(30)
      expect(service.send(:determine_max_refund_period_from_title, "6-month money back guarantee")).to eq(183)
    end

    it "returns default for unknown titles" do
      expect(service.send(:determine_max_refund_period_from_title, "Unknown policy")).to eq(30)
    end
  end
end
