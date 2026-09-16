# frozen_string_literal: true

require "spec_helper"

RSpec.describe Marketing::HoldoutAssignment do
  describe ".for_seller!" do
    let(:seller) { create(:user) }

    { 0 => "zero", 1 => "under_100", 9_999 => "under_100", 10_000 => "at_least_100" }.each do |cents, bucket|
      it "freezes #{cents} cents in the #{bucket} stratum" do
        allow(seller).to receive(:gross_sales_cents_total_as_seller).and_return(cents)
        freeze_time do
          assignment = described_class.for_seller!(seller)
          expect(assignment.prior_sales_bucket).to eq(bucket)
          expect(assignment.marketing_holdout_assigned_at).to eq(Time.current)
          expect(assignment.marketing_holdout).to eq(described_class.bucket_for(seller.id, bucket) < 20)
        end
      end
    end

    it "never reassigns after sales grow or another instance loads the seller" do
      allow(seller).to receive(:gross_sales_cents_total_as_seller).and_return(0)
      original = described_class.for_seller!(seller).attributes
      another_seller = User.find(seller.id)
      expect(another_seller).not_to receive(:gross_sales_cents_total_as_seller)

      travel 1.day do
        expect(described_class.for_seller!(another_seller).attributes).to eq(original)
      end
      expect(described_class.where(user: seller).count).to eq(1)
    end

    it "rejects changes and deletion of an assigned cohort" do
      assignment = create(:marketing_holdout_assignment, user: seller)
      expect { assignment.update!(marketing_holdout: true) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { assignment.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(assignment.reload.marketing_holdout).to eq(false)
    end

    it "uses the unique seller index to preserve the winner of a first-assignment race" do
      allow(seller).to receive(:gross_sales_cents_total_as_seller).and_return(0)
      winner = create(:marketing_holdout_assignment, user: seller, marketing_holdout: true)
      allow(described_class).to receive(:find_by).with(user_id: seller.id).and_return(nil)

      expect(described_class.for_seller!(seller).attributes).to eq(winner.attributes)
      expect(described_class.where(user: seller).count).to eq(1)
    end
  end

  describe ".bucket_for" do
    it "pins the versioned deterministic hash independently for each sales stratum" do
      expect(described_class.bucket_for(1, "zero")).to eq(22)
      expect(described_class.bucket_for(1, "under_100")).to eq(5)
      expect(described_class.bucket_for(1, "at_least_100")).to eq(16)
    end

    it "allocates approximately 20 percent independently in each stratum" do
      described_class::SALES_BUCKETS.each do |stratum|
        held_out = (1..10_000).count { described_class.bucket_for(_1, stratum) < 20 }
        expect(held_out).to be_between(1_850, 2_150)
      end
    end
  end
end
