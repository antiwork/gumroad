# frozen_string_literal: true

require "spec_helper"

describe Onetime::SetMaxAllowedRefundPeriodForPurchaseRefundPolicies do
  let(:purchase_1) { create(:purchase) }
  let(:purchase_2) { create(:purchase) }
  let(:purchase_3) { create(:purchase) }
  let(:purchase_4) { create(:purchase) }

  let!(:purchase_refund_policy_1) do
    purchase_1.create_purchase_refund_policy!(
      title: "30-day money back guarantee",
      max_refund_period_in_days: nil,
      created_at: PurchaseRefundPolicy::MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON - 1.day
    )
  end
  let!(:purchase_refund_policy_2) do
    purchase_2.create_purchase_refund_policy!(
      title: "7-day money back guarantee",
      max_refund_period_in_days: nil,
      created_at: PurchaseRefundPolicy::MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON - 1.day
    )
  end
  let!(:purchase_refund_policy_3) do
    purchase_3.create_purchase_refund_policy!(
      title: "No refunds allowed",
      max_refund_period_in_days: nil,
      created_at: PurchaseRefundPolicy::MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON - 1.day
    )
  end
  let!(:purchase_refund_policy_already_set) do
    purchase_4.create_purchase_refund_policy!(title: "14-day money back guarantee", max_refund_period_in_days: 14)
  end

  let(:service) { described_class.new(max_id: purchase_refund_policy_already_set.id) }

  describe "#process" do
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

    describe "policies reuse data from previous policies" do
      let!(:product) { create(:product) }
      let!(:product_refund_policy) { create(:product_refund_policy, product:, title: "6-month money back guarantee", max_refund_period_in_days: 183) }

      let(:purchase) { create(:purchase, link: product) }
      let!(:purchase_refund_policy) do
        purchase.create_purchase_refund_policy!(
          title: "30-day money back guarantee",
          max_refund_period_in_days: 30,
          created_at: PurchaseRefundPolicy::MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON - 1.day
        )
      end
      let(:new_purchase) { create(:purchase, link: product) }
      let!(:new_purchase_refund_policy) do
        new_purchase.create_purchase_refund_policy!(
          title: "30-day money back guarantee",
          max_refund_period_in_days: nil,
          created_at: PurchaseRefundPolicy::MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON - 1.day
        )
      end
      let(:service_with_reuse) { described_class.new(max_id: new_purchase_refund_policy.id) }

      context "when policy title matches product refund policy title" do
        before do
          new_purchase_refund_policy.update!(title: product_refund_policy.title)
        end

        it "reuses max_refund_period_in_days from product refund policy" do
          expect { service_with_reuse.process }.to change { new_purchase_refund_policy.reload.max_refund_period_in_days }.from(nil).to(183)
        end
      end

      context "when policy title does not match product refund policy title" do
        before do
          purchase_refund_policy.update!(title: purchase_refund_policy.title)
        end

        it "reuses max_refund_period_in_days from previous policy with same title" do
          expect { service_with_reuse.process }.to change { new_purchase_refund_policy.reload.max_refund_period_in_days }.from(nil).to(30)
        end
      end
    end

    context "when title doesn't match any known pattern" do
      let(:purchase_unknown) { create(:purchase) }
      let!(:purchase_refund_policy_unknown) do
        purchase_unknown.create_purchase_refund_policy!(
          title: "Custom refund policy",
          max_refund_period_in_days: nil,
          created_at: PurchaseRefundPolicy::MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON - 1.day
        )
      end
      let(:service_with_unknown) { described_class.new(max_id: purchase_refund_policy_unknown.id) }

      it "skips records with unmatched titles" do
        expect { service_with_unknown.process }.not_to change { purchase_refund_policy_unknown.reload.max_refund_period_in_days }
      end
    end
  end

  describe "PurchaseRefundPolicy#determine_max_refund_period_in_days" do
    it "returns correct days for known titles" do
      policy_no_refunds = build(:purchase_refund_policy, title: "No refunds allowed")
      policy_7_days = build(:purchase_refund_policy, title: "7-day money back guarantee")
      policy_14_days = build(:purchase_refund_policy, title: "14-day money back guarantee")
      policy_30_days = build(:purchase_refund_policy, title: "30-day money back guarantee")
      policy_6_months = build(:purchase_refund_policy, title: "6-month money back guarantee")

      expect(policy_no_refunds.determine_max_refund_period_in_days).to eq(0)
      expect(policy_7_days.determine_max_refund_period_in_days).to eq(7)
      expect(policy_14_days.determine_max_refund_period_in_days).to eq(14)
      expect(policy_30_days.determine_max_refund_period_in_days).to eq(30)
      expect(policy_6_months.determine_max_refund_period_in_days).to eq(183)
    end

    it "returns nil for unknown titles" do
      policy_unknown = build(:purchase_refund_policy, title: "Unknown policy")
      expect(policy_unknown.determine_max_refund_period_in_days).to be_nil
    end
  end
end
