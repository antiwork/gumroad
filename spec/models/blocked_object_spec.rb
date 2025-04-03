# frozen_string_literal: true

require "spec_helper"

describe BlockedObject do
  describe ".block!" do
    describe "when blocked object doesn't exist" do
      it "creates a new blocked object record" do
        count = BlockedObject.count
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "123.456.789.0", nil, expires_in: 1.hour)
        expect(BlockedObject.all.count).to eq count + 1
        expect(BlockedObject.find_by(object_value: "123.456.789.0").blocked?).to be(true)
      end
    end

    describe "when blocked object exists" do
      it "updates the existing record" do
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "789.123.456.0", nil, expires_in: 1.hour)
        BlockedObject.unblock!("789.123.456.0")
        count = BlockedObject.count
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "789.123.456.0", nil, expires_in: 1.hour)
        expect(BlockedObject.count).to eq count
      end
    end

    context "when :expires_in is present" do
      it "blocks and sets the expiration date appropriately" do
        count = BlockedObject.active.count
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "789.124.456.0", nil, expires_in: 3.days)
        expect(BlockedObject.active.count).to eq count + 1
        expect(BlockedObject.last.expires_at).to_not be(nil)
      end

      it "is not active after the expiration date" do
        count = BlockedObject.active.count
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "789.125.456.0", nil, expires_in: -3.days)
        expect(BlockedObject.active.count).to eq count
      end
    end
  end

  describe "#unblock!" do
    let(:blocked_object) do
      ip_address = "157.45.09.212"
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], ip_address, nil, expires_in: 1.hour)

      BlockedObject.find_by(object_value: ip_address)
    end

    it "unblocks the blocked object" do
      expect(blocked_object.blocked?).to be(true)

      blocked_object.unblock!

      expect(blocked_object.blocked?).to be(false)
    end
  end

  describe ".unblock!" do
    describe "when it isn't there" do
      it "fails silently" do
        expect(BlockedObject.find_by(object_value: "lol")).to be(nil)
        expect(-> { BlockedObject.unblock!("lol") }).to_not raise_error
      end
    end

    describe "when it is there" do
      it "unblocks" do
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "456.789.123.0", nil, expires_in: 1.hour)
        expect(BlockedObject.find_by(object_value: "456.789.123.0").blocked?).to be(true)
        BlockedObject.unblock!("456.789.123.0")
        expect(BlockedObject.find_by(object_value: "456.789.123.0").blocked?).to be(false)
      end
    end
  end

  describe ".charge_processor_fingerprint" do
    let(:email) { "paypal@example.com" }

    before do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], email, nil)
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], email, nil)
    end

    it "returns the list of blocked objects with object_type 'charge_processor_fingerprint'" do
      expect(BlockedObject.charge_processor_fingerprint.count).to eq 1

      blocked_object = BlockedObject.charge_processor_fingerprint.first
      expect(blocked_object.object_type).to eq BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint]
      expect(blocked_object.object_value).to eq email
    end
  end
end
