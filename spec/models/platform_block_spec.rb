# frozen_string_literal: true

require "spec_helper"

describe PlatformBlock do
  def block(type, value, by: nil, expires_in: nil)
    now = Time.current
    record = PlatformBlock.create_or_find_by!(object_type: type, object_value: value)
    record.update!(blocked_at: now, blocked_by: by, expires_at: expires_in.present? ? now + expires_in : nil)
    record
  end

  describe "#destroy!" do
    it "removes the row" do
      record = block(BLOCKED_OBJECT_TYPES[:ip_address], "157.45.09.212", expires_in: 1.hour)
      expect(record.blocked?).to be(true)
      record.destroy!
      expect(PlatformBlock.find_by(object_value: "157.45.09.212")).to be(nil)
    end
  end

  describe "re-blocking after destroy" do
    it "creates a fresh row" do
      block(BLOCKED_OBJECT_TYPES[:ip_address], "789.123.456.0", expires_in: 1.hour)
      PlatformBlock.find_by(object_value: "789.123.456.0").destroy!
      expect(PlatformBlock.find_by(object_value: "789.123.456.0")).to be(nil)
      block(BLOCKED_OBJECT_TYPES[:ip_address], "789.123.456.0", expires_in: 1.hour)
      expect(PlatformBlock.find_by(object_value: "789.123.456.0").blocked?).to be(true)
    end
  end

  describe "expiration" do
    it "is not active after the expiration date" do
      count = PlatformBlock.active.count
      block(BLOCKED_OBJECT_TYPES[:ip_address], "789.125.456.0", expires_in: -3.days)
      expect(PlatformBlock.active.count).to eq count
    end

    it "is active before the expiration date" do
      count = PlatformBlock.active.count
      block(BLOCKED_OBJECT_TYPES[:ip_address], "789.124.456.0", expires_in: 3.days)
      expect(PlatformBlock.active.count).to eq count + 1
    end
  end

  describe "scopes per object type" do
    let(:email) { "paypal@example.com" }

    before do
      block(BLOCKED_OBJECT_TYPES[:email], email)
      block(BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], email)
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
