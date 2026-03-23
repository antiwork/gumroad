# frozen_string_literal: true

require "spec_helper"

describe User::Tier do
  describe "tier state machine" do
    it "upgrades to next tier" do
      user = create(:user)
      expect(user.tier).to eq(User::TIER_0)
      expect(user.upgrade_tier).to eq(true)
      expect(user.tier).to eq(User::TIER_1)
    end

    it "upgrades with tier override" do
      user = create(:user)
      expect(user.tier).to eq(User::TIER_0)
      expect(user.upgrade_tier(User::TIER_2)).to eq(true)
      expect(user.tier).to eq(User::TIER_2)
    end

    it "does not upgrade if tier is 1M" do
      user = create(:user, tier_state: User::TIER_4)
      expect(user.upgrade_tier).to eq(false)
    end

    it "rejects upgrade if tier does not change" do
      user = create(:user, tier_state: User::TIER_1)
      expect { user.upgrade_tier(User::TIER_1) }.to raise_error(ArgumentError)
    end

    it "rejects invalid tier in transition argument" do
      user = create(:user)
      expect { user.upgrade_tier(1234) }.to raise_error(ArgumentError)
    end

    it "rejects invalid upgrade" do
      user = create(:user, tier_state: User::TIER_3)
      expect { user.upgrade_tier(User::TIER_2) }.to raise_error(ArgumentError)
    end
  end

  describe "#tier" do
    it "returns 0 if creator has not received any payments" do
      creator = create(:user)
      expect(creator.tier).to eq(0)
    end

    it "returns 0 if creator has negative sales" do
      creator = create(:user)
      sales_cents = -1000
      expect(creator.tier(sales_cents)).to eq(0)
    end

    it "returns value from tier_state column" do
      creator = create(:user, tier_state: User::TIER_1)
      expect(creator.tier_state).to eq(User::TIER_1)
      expect(creator.tier).to eq(User::TIER_1)
    end

    it "returns correct tier based on revenue" do
      creator = create(:user)

      # No earning/below $1K = tier 0
      allow(creator).to receive(:sales_cents_total).and_return(0)
      expect(creator.tier(creator.sales_cents_total)).to eq(User::TIER_0)

      allow(creator).to receive(:sales_cents_total).and_return(999_00)
      expect(creator.tier(creator.sales_cents_total)).to eq(User::TIER_0)

      # Tier $1K
      allow(creator).to receive(:sales_cents_total).and_return(1_000_00)
      expect(creator.tier(creator.sales_cents_total)).to eq(User::TIER_1)

      allow(creator).to receive(:sales_cents_total).and_return(9_999_00)
      expect(creator.tier(creator.sales_cents_total)).to eq(User::TIER_1)

      # Tier $10K
      allow(creator).to receive(:sales_cents_total).and_return(10_000_00)
      expect(creator.tier(creator.sales_cents_total)).to eq(User::TIER_2)

      allow(creator).to receive(:sales_cents_total).and_return(99_999_00)
      expect(creator.tier(creator.sales_cents_total)).to eq(User::TIER_2)

      # Tier $100K
      allow(creator).to receive(:sales_cents_total).and_return(100_000_00)
      expect(creator.tier(creator.sales_cents_total)).to eq(User::TIER_3)

      allow(creator).to receive(:sales_cents_total).and_return(999_999_00)
      expect(creator.tier(creator.sales_cents_total)).to eq(User::TIER_3)

      # Tier $1M
      allow(creator).to receive(:sales_cents_total).and_return(1_000_000_00)
      expect(creator.tier(creator.sales_cents_total)).to eq(User::TIER_4)

      allow(creator).to receive(:sales_cents_total).and_return(10_000_000_00)
      expect(creator.tier(creator.sales_cents_total)).to eq(User::TIER_4)
    end
  end
end
