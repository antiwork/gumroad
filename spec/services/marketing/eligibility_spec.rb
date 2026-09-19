# frozen_string_literal: true

require "spec_helper"

RSpec.describe Marketing::Eligibility do
  let(:seller) { create(:user) }

  it "assigns before flag evaluation, even while the rollout is off" do
    expect { described_class.enabled_for?(seller) }.to change(Marketing::HoldoutAssignment, :count).by(1)
    expect(described_class.enabled_for?(seller)).to eq(false)
  end

  [0, 5, 50, 100].each do |percentage|
    it "keeps a holdout disabled at #{percentage} percent despite an actor override" do
      create(:marketing_holdout_assignment, user: seller, marketing_holdout: true)
      Feature.activate_percentage(:auto_marketing, percentage)
      Feature.activate_user(:auto_marketing, seller)

      expect(described_class.enabled_for?(seller)).to eq(false)
      expect(Feature.active?(:auto_marketing, seller)).to eq(false)
      expect(Feature.active?("auto_marketing", seller)).to eq(false)
      expect(Feature.inactive?(:auto_marketing, seller)).to eq(true)
    end
  end

  it "keeps holdouts disabled under a global override too" do
    create(:marketing_holdout_assignment, user: seller, marketing_holdout: true)
    Feature.activate(:auto_marketing)
    expect(described_class.enabled_for?(seller)).to eq(false)
  end

  it "applies the normal flag gates to treatment sellers" do
    create(:marketing_holdout_assignment, user: seller)
    expect(described_class.enabled_for?(seller)).to eq(false)
    Feature.activate_user(:auto_marketing, seller)
    expect(described_class.enabled_for?(seller)).to eq(true)
    Feature.deactivate_user(:auto_marketing, seller)
    Feature.activate_percentage(:auto_marketing, 100)
    expect(described_class.enabled_for?(seller)).to eq(true)
  end

  it "preserves global flag inspection without a seller" do
    expect(Feature.active?(:auto_marketing)).to eq(false)
    Feature.activate(:auto_marketing)
    expect(Feature.active?(:auto_marketing)).to eq(true)
    expect(Feature.inactive?(:auto_marketing)).to eq(false)
    expect(Marketing::HoldoutAssignment.count).to eq(0)
  end

  it "fails closed without a persisted seller" do
    Feature.activate(:auto_marketing)
    expect(described_class.enabled_for?(nil)).to eq(false)
    expect(described_class.enabled_for?(build(:user))).to eq(false)
  end

  # RedisFailOpen re-raises for a gate it has not memoized yet, so a stalled read
  # reaches the caller as an exception rather than as a false.
  [RedisClient::ReadTimeoutError, Redis::TimeoutError].each do |error_class|
    it "treats a treatment seller as not enabled when the flag read stalls with #{error_class}" do
      create(:marketing_holdout_assignment, user: seller)
      allow(Flipper).to receive(:enabled?).with(:auto_marketing, seller).and_raise(error_class.new("Waited 1.0 seconds"))

      expect(described_class.enabled_for?(seller)).to eq(false)
    end
  end
end
