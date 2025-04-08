# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::SetMaxAllowedRefundPeriodForProductRefundPolicies do
  let(:product_one) { create(:product) }
  let(:product_two) { create(:product) }
  let!(:policy_one) { create(:product_refund_policy, product: product_one, max_refund_period_in_days: nil) }
  let!(:policy_two) { create(:product_refund_policy, product: product_two, max_refund_period_in_days: nil) }
  let!(:policy_with_value) { create(:product_refund_policy, max_refund_period_in_days: 30) }

  describe ".reset_last_processed_id" do
    it "deletes the redis key" do
      $redis.set(described_class::LAST_PROCESSED_ID_KEY, 123)
      described_class.reset_last_processed_id
      expect($redis.get(described_class::LAST_PROCESSED_ID_KEY)).to be_nil
    end
  end

  describe "#process" do
    subject(:process) { described_class.new(max_id: policy_two.id).process }

    before do
      allow(ReplicaLagWatcher).to receive(:watch)
      allow_any_instance_of(ProductRefundPolicy).to receive(:determine_max_refund_period_in_days).and_return(14)
    end

    it "updates eligible policies with max_refund_period_in_days" do
      expect do
        process
      end.to change { policy_one.reload.max_refund_period_in_days }.from(nil).to(14)
        .and change { policy_two.reload.max_refund_period_in_days }.from(nil).to(14)
    end

    it "skips policies that already have max_refund_period_in_days set" do
      expect do
        process
      end.to not_change { policy_with_value.reload.max_refund_period_in_days }
    end

    it "updates the last processed id in redis" do
      process
      expect($redis.get(described_class::LAST_PROCESSED_ID_KEY).to_i).to eq(policy_two.id)
    end

    context "when there's a last processed id in redis" do
      before do
        $redis.set(described_class::LAST_PROCESSED_ID_KEY, policy_one.id)
      end

      it "only processes records after the last processed id" do
        expect do
          process
        end.to not_change { policy_one.reload.max_refund_period_in_days }
          .and change { policy_two.reload.max_refund_period_in_days }.from(nil).to(14)
      end
    end

    context "when an error occurs while processing a policy" do
      before do
        # Create a class-level stub for with_lock that raises an error only for policy_one
        allow_any_instance_of(ProductRefundPolicy).to receive(:with_lock) do |policy, &block|
          if policy.id == policy_one.id
            raise StandardError.new("Test error")
          else
            block.call
          end
        end
        puts "policy_one ID: #{policy_one.id}"
        puts "policy_two ID: #{policy_two.id}"
      end

      it "continues processing other policies" do
        expect do
          process
        end.to not_change { policy_one.reload.max_refund_period_in_days }
          .and change { policy_two.reload.max_refund_period_in_days }.from(nil).to(14)
      end

      it "logs invalid policy ids" do
        expect(Rails.logger).to receive(:info).with(/Processing product refund policies/).at_least(:once)
        expect(Rails.logger).to receive(:info).with(/updated with max allowed refund period/).at_least(:once)
        expect(Rails.logger).to receive(:info).with(/Invalid product refund policy ids: /).at_least(:once)

        process
      end
    end
  end
end
