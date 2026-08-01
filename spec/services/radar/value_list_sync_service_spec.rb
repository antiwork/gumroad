# frozen_string_literal: true

require "spec_helper"

describe Radar::ValueListSyncService do
  let(:service) { described_class.new }

  let(:value_list) { double("ValueList", id: "rsl_123") }

  describe "#sync_blocked_emails" do
    before do
      allow(Stripe::Radar::ValueList).to receive(:list)
        .with(alias: "gumroad_blocked_emails", limit: 1)
        .and_return(double(data: [value_list]))
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
      allow(Stripe::Radar::ValueList).to receive(:list)
        .with(alias: "gumroad_blocked_emails", limit: 1)
        .and_return(double(data: []))

      expect(Stripe::Radar::ValueList).to receive(:create).with(
        alias: "gumroad_blocked_emails",
        name: "Gumroad Blocked Emails",
        item_type: "email"
      ).and_return(value_list)

      service.sync_blocked_emails
    end

    it "returns the existing list when Stripe already has a list with that alias (no create call)" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "existing@example.com")
      allow(Stripe::Radar::ValueListItem).to receive(:create)

      expect(Stripe::Radar::ValueList).not_to receive(:create)

      service.sync_blocked_emails
    end

    it "recovers when create races against an existing alias" do
      allow(Stripe::Radar::ValueList).to receive(:list)
        .with(alias: "gumroad_blocked_emails", limit: 1)
        .and_return(double(data: []), double(data: [value_list]))
      allow(Stripe::Radar::ValueList).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("A list with the alias 'gumroad_blocked_emails' already exists", "alias"))
      allow(Stripe::Radar::ValueListItem).to receive(:create)

      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "race@example.com")

      expect { service.sync_blocked_emails }.not_to raise_error
    end

    it "raises a descriptive error if race recovery cannot find the list" do
      allow(Stripe::Radar::ValueList).to receive(:list)
        .with(alias: "gumroad_blocked_emails", limit: 1)
        .and_return(double(data: []), double(data: []))
      allow(Stripe::Radar::ValueList).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("A list with the alias 'gumroad_blocked_emails' already exists", "alias"))

      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "lost@example.com")

      expect { service.sync_blocked_emails }
        .to raise_error(RuntimeError, /Radar value list 'gumroad_blocked_emails' could not be found/)
    end

    it "does not swallow non-'already exists' errors from the initial lookup" do
      allow(Stripe::Radar::ValueList).to receive(:list)
        .with(alias: "gumroad_blocked_emails", limit: 1)
        .and_raise(Stripe::InvalidRequestError.new("Internal server error", "alias"))

      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "boom@example.com")

      expect { service.sync_blocked_emails }
        .to raise_error(Stripe::InvalidRequestError, /Internal server error/)
    end

    it "ignores duplicate item errors" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "dup@example.com")

      allow(Stripe::Radar::ValueListItem).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("This value already exists", "value", code: "value_list_item_already_exists"))

      expect { service.sync_blocked_emails }.not_to raise_error
    end

    it "ignores case-insensitive duplicate item errors (Stripe returns code: nil)" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "dup2@example.com")

      allow(Stripe::Radar::ValueListItem).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("This item already exists in this case-insensitive list.", "value"))

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
      allow(Stripe::Radar::ValueList).to receive(:list)
        .with(alias: "gumroad_blocked_cards", limit: 1)
        .and_return(double(data: [value_list]))
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

    it "ignores case-insensitive duplicate item errors (Stripe returns code: nil)" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "fpdup2")

      allow(Stripe::Radar::ValueListItem).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("This item already exists in this case-insensitive list.", "value"))

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

    it "returns the existing list when Stripe already has a list with that alias (no create call)" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "fpexisting")
      allow(Stripe::Radar::ValueListItem).to receive(:create)

      expect(Stripe::Radar::ValueList).not_to receive(:create)

      service.sync_blocked_cards
    end

    it "recovers when create races against an existing alias" do
      allow(Stripe::Radar::ValueList).to receive(:list)
        .with(alias: "gumroad_blocked_cards", limit: 1)
        .and_return(double(data: []), double(data: [value_list]))
      allow(Stripe::Radar::ValueList).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("A list with the alias 'gumroad_blocked_cards' already exists", "alias"))
      allow(Stripe::Radar::ValueListItem).to receive(:create)

      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "fprace")

      expect { service.sync_blocked_cards }.not_to raise_error
    end
  end

  describe "#remove_block" do
    before do
      allow(Stripe::Radar::ValueList).to receive(:list).and_return(double(data: [value_list]))
    end

    def stub_item(value, id)
      allow(Stripe::Radar::ValueListItem).to receive(:list)
        .with(value_list: "rsl_123", value: value)
        .and_return(double(data: [double("ValueListItem", id:)]))
    end

    it "removes an unblocked email without waiting for the daily window" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "now@example.com")
      block.update_columns(blocked_at: nil, expires_at: nil)
      stub_item("now@example.com", "rsli_1")

      expect(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_1")

      expect(service.remove_block(block)).to be(true)
    end

    it "removes a block whose unblock happened outside the sync window, which the daily job never revisits" do
      block = travel_to(10.days.ago) { PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "stranded@example.com") }
      block.update_columns(blocked_at: nil, expires_at: nil, updated_at: 10.days.ago)
      stub_item("stranded@example.com", "rsli_2")

      expect(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_2")

      expect(service.remove_block(block)).to be(true)
    end

    it "removes an unblocked card fingerprint" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "UTLL7GN3iOh1m111")
      block.update_columns(blocked_at: nil, expires_at: nil)
      stub_item("UTLL7GN3iOh1m111", "rsli_3")

      expect(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_3")

      expect(service.remove_block(block)).to be(true)
    end

    it "leaves Radar alone when the row was re-blocked between enqueue and run" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "reblocked@example.com")

      expect(Stripe::Radar::ValueListItem).not_to receive(:delete)

      expect(service.remove_block(block)).to be(false)
    end

    it "skips types that were never pushed to Radar" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "157.45.09.212", expires_in: 1.hour)
      block.update_columns(blocked_at: nil, expires_at: nil)

      expect(Stripe::Radar::ValueListItem).not_to receive(:delete)

      expect(service.remove_block(block)).to be(false)
    end

    it "skips fingerprints the add path would have rejected, mirroring the daily job's filter" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "not a fingerprint")
      block.update_columns(blocked_at: nil, expires_at: nil)

      expect(Stripe::Radar::ValueListItem).not_to receive(:delete)

      expect(service.remove_block(block)).to be(false)
    end
  end

  describe ".syncs?" do
    it "is true only for the types the daily job pushes to Radar" do
      expect(described_class.syncs?(PlatformBlock::TYPES[:email])).to be(true)
      expect(described_class.syncs?(PlatformBlock::TYPES[:charge_processor_fingerprint])).to be(true)

      (PlatformBlock::TYPES.values - [PlatformBlock::TYPES[:email], PlatformBlock::TYPES[:charge_processor_fingerprint]]).each do |type|
        expect(described_class.syncs?(type)).to be(false)
      end
    end
  end
end
