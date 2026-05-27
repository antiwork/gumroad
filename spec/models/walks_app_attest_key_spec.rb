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

  describe "#consume_synthesis_attempt" do
    let(:trial) { create(:walks_free_trial) }

    it "returns true and increments the counter for each call under the cap" do
      WalksFreeTrial::MAX_SYNTHESIS_ATTEMPTS.times do |i|
        expect(trial.consume_synthesis_attempt).to be(true)
        expect(trial.reload.synthesis_attempts).to eq(i + 1)
      end
    end

    it "returns false once the cap is reached and leaves the counter pinned" do
      WalksFreeTrial::MAX_SYNTHESIS_ATTEMPTS.times { trial.consume_synthesis_attempt }
      expect(trial.consume_synthesis_attempt).to be(false)
      expect(trial.reload.synthesis_attempts).to eq(WalksFreeTrial::MAX_SYNTHESIS_ATTEMPTS)
    end

    it "is race-safe: two parallel attempts at the cap can't both succeed" do
      trial.update!(synthesis_attempts: WalksFreeTrial::MAX_SYNTHESIS_ATTEMPTS - 1)
      a = WalksFreeTrial.find(trial.id)
      b = WalksFreeTrial.find(trial.id)
      results = [a.consume_synthesis_attempt, b.consume_synthesis_attempt]
      expect(results.count(true)).to eq(1)
      expect(results.count(false)).to eq(1)
      expect(trial.reload.synthesis_attempts).to eq(WalksFreeTrial::MAX_SYNTHESIS_ATTEMPTS)
    end
  end
end
