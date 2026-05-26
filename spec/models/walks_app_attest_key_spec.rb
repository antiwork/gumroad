# frozen_string_literal: true

require "spec_helper"

describe WalksAppAttestKey do
  describe "#advance_counter!" do
    it "updates the counter and last_used_at when the new value is strictly greater" do
      key = create(:walks_app_attest_key, counter: 3)

      expect(key.advance_counter!(4)).to be(true)
      expect(key.reload.counter).to eq(4)
      expect(key.last_used_at).to be_within(2.seconds).of(Time.current)
    end

    it "rejects an equal counter (replay)" do
      key = create(:walks_app_attest_key, counter: 5)
      expect(key.advance_counter!(5)).to be(false)
      expect(key.reload.counter).to eq(5)
    end

    it "rejects a lower counter" do
      key = create(:walks_app_attest_key, counter: 7)
      expect(key.advance_counter!(2)).to be(false)
      expect(key.reload.counter).to eq(7)
    end
  end

  describe "#free_trial_consumed?" do
    it "is false without a WalksFreeTrial row" do
      key = create(:walks_app_attest_key)
      expect(key.free_trial_consumed?).to be(false)
    end

    it "is true once a free trial has been recorded" do
      key = create(:walks_app_attest_key)
      create(:walks_free_trial, walks_app_attest_key: key)
      expect(key.reload.free_trial_consumed?).to be(true)
    end
  end
end

describe WalksFreeTrial do
  describe ".consume" do
    it "creates one row per key and returns true on first call" do
      key = create(:walks_app_attest_key)
      expect(described_class.consume(walks_app_attest_key: key)).to be(true)
      expect(described_class.count).to eq(1)
    end

    it "returns false on a duplicate consume for the same key" do
      key = create(:walks_app_attest_key)
      described_class.consume(walks_app_attest_key: key)
      expect(described_class.consume(walks_app_attest_key: key)).to be(false)
      expect(described_class.where(walks_app_attest_key_id: key.id).count).to eq(1)
    end
  end
end
