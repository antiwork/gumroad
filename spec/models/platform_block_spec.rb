# frozen_string_literal: true

require "spec_helper"

describe PlatformBlock do
  describe ".add!" do
    it "creates a new row" do
      expect do
        PlatformBlock.add!(object_type: BLOCKED_OBJECT_TYPES[:email], object_value: "fraud@example.com", by: 1)
      end.to change { PlatformBlock.count }.by(1)

      record = PlatformBlock.find_by(object_value: "fraud@example.com")
      expect(record.object_type).to eq(BLOCKED_OBJECT_TYPES[:email])
      expect(record.blocked_by).to eq(1)
      expect(record.blocked_at).to be_within(1.minute).of(Time.current)
      expect(record.expires_at).to be_nil
    end

    it "sets expires_at from expires_in" do
      record = PlatformBlock.add!(object_type: BLOCKED_OBJECT_TYPES[:ip_address], object_value: "157.45.9.212", expires_in: 1.hour)
      expect(record.expires_at).to be_within(1.minute).of(1.hour.from_now)
    end

    it "refreshes an existing row instead of inserting a second one" do
      first = PlatformBlock.add!(object_type: BLOCKED_OBJECT_TYPES[:ip_address], object_value: "1.2.3.4", expires_in: 1.hour)
      expect do
        second = PlatformBlock.add!(object_type: BLOCKED_OBJECT_TYPES[:ip_address], object_value: "1.2.3.4", expires_in: 6.hours)
        expect(second.id).to eq(first.id)
      end.not_to change { PlatformBlock.count }
      expect(first.reload.expires_at).to be_within(1.minute).of(6.hours.from_now)
    end

    it "returns the hydrated record" do
      record = PlatformBlock.add!(object_type: BLOCKED_OBJECT_TYPES[:email], object_value: "x@example.com")
      expect(record).to be_a(PlatformBlock)
      expect(record).to be_blocked
    end
  end

  describe "#destroy!" do
    it "removes the row" do
      record = PlatformBlock.add!(object_type: BLOCKED_OBJECT_TYPES[:ip_address], object_value: "157.45.09.212", expires_in: 1.hour)
      expect(record.blocked?).to be(true)
      record.destroy!
      expect(PlatformBlock.find_by(object_value: "157.45.09.212")).to be(nil)
    end
  end

  describe "expiration" do
    it "is not active after the expiration date" do
      count = PlatformBlock.active.count
      PlatformBlock.add!(object_type: BLOCKED_OBJECT_TYPES[:ip_address], object_value: "789.125.456.0", expires_in: -3.days)
      expect(PlatformBlock.active.count).to eq count
    end

    it "is active before the expiration date" do
      count = PlatformBlock.active.count
      PlatformBlock.add!(object_type: BLOCKED_OBJECT_TYPES[:ip_address], object_value: "789.124.456.0", expires_in: 3.days)
      expect(PlatformBlock.active.count).to eq count + 1
    end
  end

  describe "scopes per object type" do
    let(:email) { "paypal@example.com" }

    before do
      PlatformBlock.add!(object_type: BLOCKED_OBJECT_TYPES[:email], object_value: email)
      PlatformBlock.add!(object_type: BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], object_value: email)
    end

    it "filters by charge_processor_fingerprint type" do
      expect(PlatformBlock.charge_processor_fingerprint.count).to eq 1

      record = PlatformBlock.charge_processor_fingerprint.first
      expect(record.object_type).to eq BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint]
      expect(record.object_value).to eq email
    end
  end

  describe "expires_at validation" do
    context "when object_type is ip_address" do
      let(:object_type) { BLOCKED_OBJECT_TYPES[:ip_address] }
      let(:object_value) { "192.168.1.1" }

      context "when blocked_at is present" do
        it "is invalid without expires_at" do
          record = PlatformBlock.new(object_type:, object_value:, blocked_at: Time.current)

          expect(record).not_to be_valid
          expect(record.errors[:expires_at]).to include("can't be blank")
        end

        it "is valid with expires_at" do
          record = PlatformBlock.new(
            object_type:,
            object_value:,
            blocked_at: Time.current,
            expires_at: Time.current + 1.hour
          )

          expect(record).to be_valid
        end
      end

      context "when blocked_at is nil" do
        it "is valid without expires_at" do
          record = PlatformBlock.new(object_type:, object_value:, blocked_at: nil, expires_at: nil)
          expect(record).to be_valid
        end
      end
    end

    context "when object_type is NOT ip_address" do
      let(:object_type) { BLOCKED_OBJECT_TYPES[:email] }
      let(:object_value) { "test@example.com" }

      it "is valid without expires_at" do
        record = PlatformBlock.new(object_type:, object_value:, blocked_at: Time.current, expires_at: nil)
        expect(record).to be_valid
      end

      it "is valid with expires_at" do
        record = PlatformBlock.new(object_type:, object_value:, blocked_at: Time.current, expires_at: Time.current + 1.hour)
        expect(record).to be_valid
      end
    end
  end

  describe "object_type validation" do
    it "rejects unknown object types" do
      record = PlatformBlock.new(object_type: "not_a_real_type", object_value: "x")
      expect(record).not_to be_valid
      expect(record.errors[:object_type]).to be_present
    end
  end
end
