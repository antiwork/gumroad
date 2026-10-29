# frozen_string_literal: true

require "spec_helper"

describe SellerPlan::Experiment do
  let(:user) { create(:user) }

  def enable_experiment(seller, started_at: 1.day.ago)
    allow(Feature).to receive(:active?).and_call_original
    allow(Feature).to receive(:active?).with(described_class::FLAG, anything).and_return(true)
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("SELLER_PLAN_EXPERIMENT_START").and_return(started_at.iso8601)
    allow(GlobalConfig).to receive(:get).with("SELLER_PLAN_PRICE_5").and_return("price_five")
    allow(GlobalConfig).to receive(:get).with("SELLER_PLAN_PRICE_10").and_return("price_ten")
    seller
  end

  describe ".arm_for" do
    it "keeps a seller in one arm across calls" do
      expect(described_class.arm_for(user)).to eq(described_class.arm_for(user))
    end

    it "splits sellers across the control and price arms" do
      tally = (1..300).map { described_class.arm_for(build(:user, id: _1)) }.tally

      expect(tally.keys).to match_array(%w[control five ten])
      expect(tally["control"]).to be_between(100, 200)
      expect(tally["five"]).to be_between(30, 125)
      expect(tally["ten"]).to be_between(30, 125)
    end
  end

  describe ".offer_for" do
    let(:product) { create(:product, user:, draft: true) }

    it "records an offer for a seller in a price arm" do
      enable_experiment(user)
      allow(described_class).to receive(:arm_for).and_return("ten")

      offer = described_class.offer_for(product)

      expect(offer.arm).to eq("ten")
      expect(offer.price_cents).to eq(1000)
      expect(offer.status).to eq("offered")
    end

    it "returns nil for the control arm" do
      enable_experiment(user)
      allow(described_class).to receive(:arm_for).and_return("control")

      expect(described_class.offer_for(product)).to be_nil
      expect(SellerPlanOffer.count).to eq(0)
    end

    it "returns nil when the arm's Stripe price has not been created" do
      enable_experiment(user)
      allow(described_class).to receive(:arm_for).and_return("ten")
      allow(GlobalConfig).to receive(:get).with("SELLER_PLAN_PRICE_10").and_return(nil)

      expect(described_class.offer_for(product)).to be_nil
    end

    it "returns nil while the flag is off" do
      allow(Feature).to receive(:active?).and_call_original
      allow(Feature).to receive(:active?).with(described_class::FLAG, anything).and_return(false)

      expect(described_class.offer_for(product)).to be_nil
    end

    it "returns nil for a product that has been live before" do
      enable_experiment(user)
      allow(described_class).to receive(:arm_for).and_return("ten")
      product.update!(draft: false)

      expect(described_class.offer_for(product)).to be_nil
    end

    it "returns nil for team accounts" do
      enable_experiment(user)
      allow(described_class).to receive(:arm_for).and_return("ten")
      user.update!(flags: user.flags | User.flag_mapping["flags"][:is_team_member])

      expect(described_class.offer_for(product)).to be_nil
    end

    it "returns the existing offer when the seller already has an active plan" do
      enable_experiment(user)
      allow(described_class).to receive(:arm_for).and_return("ten")
      offer = described_class.offer_for(product)
      offer.update!(status: "active")

      second_product = create(:product, user:, draft: true)

      expect(described_class.offer_for(second_product)).to eq(offer)
    end
  end
end
