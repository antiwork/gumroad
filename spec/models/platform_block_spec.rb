# frozen_string_literal: true

require "spec_helper"

describe PlatformBlock do
  describe ".add!" do
    it "creates a new row" do
      expect do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "fraud@example.com", by: 1)
      end.to change { PlatformBlock.count }.by(1)

      record = PlatformBlock.find_by(object_value: "fraud@example.com")
      expect(record.object_type).to eq(PlatformBlock::TYPES[:email])
      expect(record.blocked_by).to eq(1)
      expect(record.blocked_at).to be_within(1.minute).of(Time.current)
      expect(record.expires_at).to be_nil
    end

    it "sets expires_at from expires_in" do
      record = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "157.45.9.212", expires_in: 1.hour)
      expect(record.expires_at).to be_within(1.minute).of(1.hour.from_now)
    end

    it "refreshes an existing row instead of inserting a second one" do
      first = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "1.2.3.4", expires_in: 1.hour)
      expect do
        second = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "1.2.3.4", expires_in: 6.hours)
        expect(second.id).to eq(first.id)
      end.not_to change { PlatformBlock.count }
      expect(first.reload.expires_at).to be_within(1.minute).of(6.hours.from_now)
    end

    it "returns the hydrated record" do
      record = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "x@example.com")
      expect(record).to be_a(PlatformBlock)
      expect(record).to be_persisted
      expect(record.object_value).to eq("x@example.com")
    end
  end

  describe "#unblock!" do
    it "nulls blocked_at and expires_at without removing the row" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "157.45.09.212", expires_in: 1.hour)
      record = PlatformBlock.find_by(object_value: "157.45.09.212")
      expect(record.blocked_at).to be_present

      record.unblock!

      expect(PlatformBlock.find_by(object_value: "157.45.09.212")).to be_present
      expect(record.reload.blocked_at).to be_nil
      expect(record.expires_at).to be_nil
      expect(PlatformBlock.active.where(object_value: "157.45.09.212")).to be_empty
    end

    it "lets a subsequent add! reuse the existing row" do
      first = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "reblock@example.com")
      first.unblock!

      second = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "reblock@example.com")
      expect(second.id).to eq(first.id)
      expect(second.blocked_at).to be_present
    end
  end

  describe "expiration" do
    it "is not active after the expiration date" do
      count = PlatformBlock.active.count
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "789.125.456.0", expires_in: -3.days)
      expect(PlatformBlock.active.count).to eq count
    end

    it "is active before the expiration date" do
      count = PlatformBlock.active.count
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "789.124.456.0", expires_in: 3.days)
      expect(PlatformBlock.active.count).to eq count + 1
    end
  end

  describe "scopes per object type" do
    let(:email) { "paypal@example.com" }

    before do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: email)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: email)
    end

    it "filters by charge_processor_fingerprint type" do
      expect(PlatformBlock.charge_processor_fingerprint.count).to eq 1

      record = PlatformBlock.charge_processor_fingerprint.first
      expect(record.object_type).to eq PlatformBlock::TYPES[:charge_processor_fingerprint]
      expect(record.object_value).to eq email
    end
  end

  describe "add! ip_address requires expires_in" do
    it "raises ArgumentError when expires_in is missing" do
      expect do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "192.168.1.1")
      end.to raise_error(ArgumentError, /expires_in is required/)
    end

    it "succeeds when expires_in is provided" do
      record = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "192.168.1.1", expires_in: 1.hour)
      expect(record.expires_at).to be_present
    end

    it "allows other types without expires_in" do
      expect do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "foo@example.com")
      end.not_to raise_error
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
