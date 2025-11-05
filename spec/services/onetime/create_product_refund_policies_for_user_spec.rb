# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::CreateProductRefundPoliciesForUser do
  let(:user) { create(:user) }
  let(:service) { described_class.new(user_id: user.id, max_refund_period_in_days: max_refund_period_in_days) }
  let(:max_refund_period_in_days) { 0 }

  describe "#initialize" do
    it "sets the user_id" do
      expect(service.user_id).to eq(user.id)
    end

    it "sets the max_refund_period_in_days to 0 by default" do
      service_with_defaults = described_class.new(user_id: user.id)
      expect(service_with_defaults.max_refund_period_in_days).to eq(0)
    end

    it "allows custom max_refund_period_in_days" do
      custom_service = described_class.new(user_id: user.id, max_refund_period_in_days: 30)
      expect(custom_service.max_refund_period_in_days).to eq(30)
    end

    it "initializes empty results hash" do
      expect(service.results).to eq({ success: [], errors: [] })
    end
  end

  describe "#process" do
    let!(:product_without_policy_1) { create(:product, user: user) }
    let!(:product_without_policy_2) { create(:product, user: user) }
    let!(:product_with_policy) { create(:product, user: user) }
    let!(:existing_policy) { create(:product_refund_policy, product: product_with_policy, seller: user) }

    before do
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)
    end

    it "creates refund policies for products without policies" do
      expect do
        service.process
      end.to change { ProductRefundPolicy.count }.by(2)
    end

    it "does not create policies for products that already have one" do
      service.process

      expect(product_with_policy.reload.product_refund_policy).to eq(existing_policy)
    end

    it "sets the correct max_refund_period_in_days" do
      service.process

      expect(product_without_policy_1.reload.product_refund_policy.max_refund_period_in_days).to eq(0)
      expect(product_without_policy_2.reload.product_refund_policy.max_refund_period_in_days).to eq(0)
    end

    it "sets the seller correctly" do
      service.process

      expect(product_without_policy_1.reload.product_refund_policy.seller).to eq(user)
      expect(product_without_policy_2.reload.product_refund_policy.seller).to eq(user)
    end

    it "returns results with successful creations" do
      results = service.process

      expect(results[:success].count).to eq(2)
      expect(results[:success].first).to include(
        product_id: product_without_policy_1.id,
        product_name: product_without_policy_1.name,
        policy_title: "No refunds allowed"
      )
      expect(results[:success].second).to include(
        product_id: product_without_policy_2.id,
        product_name: product_without_policy_2.name,
        policy_title: "No refunds allowed"
      )
    end

    context "when there are no products without policies" do
      let!(:product_without_policy_1) { nil }
      let!(:product_without_policy_2) { nil }

      it "returns empty results" do
        results = service.process

        expect(results[:success]).to be_empty
        expect(results[:errors]).to be_empty
      end

      it "logs zero products found" do
        service.process

        expect(Rails.logger).to have_received(:info).with(
          "Found 0 products without refund policies"
        )
      end
    end

    context "with custom refund period" do
      let(:max_refund_period_in_days) { 30 }

      it "creates policies with the specified refund period" do
        service.process

        expect(product_without_policy_1.reload.product_refund_policy.max_refund_period_in_days).to eq(30)
        expect(product_without_policy_2.reload.product_refund_policy.max_refund_period_in_days).to eq(30)
      end
    end

    context "when user does not exist" do
      let(:service) { described_class.new(user_id: 999_999_999) }

      it "raises ActiveRecord::RecordNotFound" do
        expect { service.process }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
