# frozen_string_literal: true

require "spec_helper"

describe Radar::ValueListSyncService do
  let(:service) { described_class.new }

  let(:value_list) { double("ValueList", id: "rsl_123") }

  describe "#sync_blocked_emails" do
    before do
      allow(Stripe::Radar::ValueList).to receive(:retrieve)
        .with("gumroad_blocked_emails")
        .and_return(value_list)
      allow(Stripe::Radar::ValueListItem).to receive(:list)
        .and_return(double(data: []))
    end

    it "pushes recently blocked emails to Stripe Radar" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "bad@example.com")

      expect(Stripe::Radar::ValueListItem).to receive(:create).with(
        value_list: "rsl_123",
        value: "bad@example.com"
      )

      service.sync_blocked_emails
    end

    it "skips emails blocked more than 25 hours ago" do
      travel_to 2.days.ago do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "old@example.com")
      end

      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      service.sync_blocked_emails
    end

    it "removes recently unblocked emails from Stripe Radar" do
      blocked = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "unblocked@example.com")
      blocked.unblock!

      item = double("ValueListItem", id: "rsli_456")
      allow(Stripe::Radar::ValueListItem).to receive(:list)
        .with(value_list: "rsl_123", value: "unblocked@example.com")
        .and_return(double(data: [item]))

      expect(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_456")

      service.sync_blocked_emails
    end

    it "removes expired blocked emails from Stripe Radar" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "expired@example.com", expires_in: 1.hour)

      travel 2.hours

      item = double("ValueListItem", id: "rsli_789")
      allow(Stripe::Radar::ValueListItem).to receive(:list)
        .with(value_list: "rsl_123", value: "expired@example.com")
        .and_return(double(data: [item]))

      expect(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_789")

      service.sync_blocked_emails
    end

    it "creates the value list if it does not exist" do
      allow(Stripe::Radar::ValueList).to receive(:retrieve)
        .with("gumroad_blocked_emails")
        .and_raise(Stripe::InvalidRequestError.new("No such value list", "alias", code: "resource_missing"))

      expect(Stripe::Radar::ValueList).to receive(:create).with(
        alias: "gumroad_blocked_emails",
        name: "Gumroad Blocked Emails",
        item_type: "email"
      ).and_return(value_list)

      service.sync_blocked_emails
    end

    it "ignores duplicate item errors" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "dup@example.com")

      allow(Stripe::Radar::ValueListItem).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("This value already exists", "value", code: "value_list_item_already_exists"))

      expect { service.sync_blocked_emails }.not_to raise_error
    end

    it "picks up re-blocked emails by filtering on blocked_at" do
      travel_to 1.month.ago do
        blocked = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "reblocked@example.com")
        blocked.unblock!
      end

      # Re-block now
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "reblocked@example.com")

      expect(Stripe::Radar::ValueListItem).to receive(:create).with(
        value_list: "rsl_123",
        value: "reblocked@example.com"
      )

      service.sync_blocked_emails
    end
  end

  describe "#sync_blocked_cards" do
    before do
      allow(Stripe::Radar::ValueList).to receive(:retrieve)
        .with("gumroad_blocked_cards")
        .and_return(value_list)
      allow(Stripe::Radar::ValueListItem).to receive(:list)
        .and_return(double(data: []))
    end

    it "pushes recently blocked card fingerprints to Stripe Radar" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "fpabc123")

      expect(Stripe::Radar::ValueListItem).to receive(:create).with(
        value_list: "rsl_123",
        value: "fpabc123"
      )

      service.sync_blocked_cards
    end

    it "skips fingerprints blocked more than 25 hours ago" do
      travel_to 2.days.ago do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "fpold")
      end

      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      service.sync_blocked_cards
    end

    it "ignores duplicate item errors" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "fpdup")

      allow(Stripe::Radar::ValueListItem).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("This value already exists", "value", code: "value_list_item_already_exists"))

      expect { service.sync_blocked_cards }.not_to raise_error
    end

    it "removes recently unblocked card fingerprints from Stripe Radar" do
      blocked = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "fpunblock1")
      blocked.unblock!

      item = double("ValueListItem", id: "rsli_card_1")
      allow(Stripe::Radar::ValueListItem).to receive(:list)
        .with(value_list: "rsl_123", value: "fpunblock1")
        .and_return(double(data: [item]))

      expect(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_card_1")

      service.sync_blocked_cards
    end

    it "removes expired blocked card fingerprints from Stripe Radar" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "fpexpire1", expires_in: 1.hour)

      travel 2.hours

      item = double("ValueListItem", id: "rsli_card_2")
      allow(Stripe::Radar::ValueListItem).to receive(:list)
        .with(value_list: "rsl_123", value: "fpexpire1")
        .and_return(double(data: [item]))

      expect(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_card_2")

      service.sync_blocked_cards
    end
  end
end
