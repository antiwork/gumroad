# frozen_string_literal: true

require "spec_helper"

describe Link, "paid-publish gate" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, draft: true) }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("SELLER_PLAN_EXPERIMENT_START").and_return(1.day.ago.iso8601)
    allow(GlobalConfig).to receive(:get).with("SELLER_PLAN_PRICE_5").and_return("price_five")
    allow(GlobalConfig).to receive(:get).with("SELLER_PLAN_PRICE_10").and_return("price_ten")
    allow(Feature).to receive(:active?).and_call_original
    allow(Feature).to receive(:active?).with(SellerPlan::Experiment::FLAG, anything).and_return(true)
  end

  it "holds the first publish until the seller starts the plan" do
    allow(SellerPlan::Experiment).to receive(:arm_for).and_return("ten")

    expect { product.publish! }.to raise_error(Link::LinkInvalid, /seller plan/)
    expect(product.reload).to be_draft
    expect(SellerPlanOffer.find_by(user_id: seller.id)).to have_attributes(arm: "ten", status: "offered")
  end

  it "publishes once the plan is active" do
    allow(SellerPlan::Experiment).to receive(:arm_for).and_return("ten")
    SellerPlanOffer.record_offer!(user: seller, product: product, arm: "ten", price_cents: 1000).update!(status: "active")

    product.publish!

    expect(product.reload).to be_published
  end

  it "keeps the free flow while the flag is off" do
    allow(Feature).to receive(:active?).and_call_original
    allow(Feature).to receive(:active?).with(SellerPlan::Experiment::FLAG, anything).and_return(false)
    allow(SellerPlan::Experiment).to receive(:arm_for).and_return("ten")

    product.publish!

    expect(product.reload).to be_published
    expect(SellerPlanOffer.count).to eq(0)
  end

  it "leaves the control arm on the free flow" do
    allow(SellerPlan::Experiment).to receive(:arm_for).and_return("control")

    product.publish!

    expect(product.reload).to be_published
    expect(SellerPlanOffer.count).to eq(0)
  end

  it "does not gate a publish that an admin performs" do
    allow(SellerPlan::Experiment).to receive(:arm_for).and_return("ten")

    product.publish_by_admin!

    expect(product.reload).to be_published
  end

  it "does not gate a listing that was already live" do
    allow(SellerPlan::Experiment).to receive(:arm_for).and_return("ten")
    product.update!(draft: false, purchase_disabled_at: Time.current)

    product.publish!

    expect(product.reload).to be_published
  end
end
