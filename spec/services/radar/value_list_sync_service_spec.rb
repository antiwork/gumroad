# frozen_string_literal: true

require "spec_helper"

describe Radar::ValueListSyncService do
  let(:service) { described_class.new }

  let(:value_list) { double("ValueList", id: "rsl_123") }

  before do
    allow(described_class).to receive(:enabled?).and_return(true)
  end

  describe ".enabled?" do
    before do
      allow(described_class).to receive(:enabled?).and_call_original
    end

    it "is disabled outside production so the shared Stripe test account's lists are never written" do
      expect(described_class.enabled?).to be(false)
    end

    it "is enabled in production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect(described_class.enabled?).to be(true)
    end

    it "can be forced on with ENABLE_RADAR_VALUE_LIST_SYNC" do
      allow(GlobalConfig).to receive(:get).with("ENABLE_RADAR_VALUE_LIST_SYNC").and_return("1")

      expect(described_class.enabled?).to be(true)
    end
  end

  describe "when sync is disabled" do
    before do
      allow(described_class).to receive(:enabled?).and_return(false)
    end

    it "does not touch Stripe Radar from add_block" do
      platform_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "testfingerprint1")

      expect(Stripe::Radar::ValueList).not_to receive(:list)
      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      expect(service.add_block(platform_block)).to be(false)
    end

    it "does not touch Stripe Radar from remove_block" do
      platform_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "cleared@example.com")
      platform_block.update_columns(blocked_at: nil, expires_at: nil)

      expect(Stripe::Radar::ValueList).not_to receive(:list)
      expect(Stripe::Radar::ValueListItem).not_to receive(:delete)

      expect(service.remove_block(platform_block)).to be(false)
    end

    it "does not touch Stripe Radar from the daily syncs" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "blocked@example.com")
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "testfingerprint2")

      expect(Stripe::Radar::ValueList).not_to receive(:list)
      expect(Stripe::Radar::ValueList).not_to receive(:create)

      service.sync_blocked_emails
      service.sync_blocked_cards
    end
  end

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

    it "removes an unblocked card fingerprint" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "UTLL7GN3iOh1m111")
      block.update_columns(blocked_at: nil, expires_at: nil)
      stub_item("UTLL7GN3iOh1m111", "rsli_3")

      expect(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_3")

      expect(service.remove_block(block)).to be(true)
    end

    it "leaves Radar alone when the row was re-blocked between enqueue and run" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "reblocked@example.com")
      block.update_columns(blocked_at: nil, expires_at: nil)
      # Re-blocked behind this handle, so only a reload can see it — deleting the reload from
      # remove_block must redden here.
      PlatformBlock.find(block.id).update_columns(blocked_at: Time.current)

      expect(Stripe::Radar::ValueListItem).not_to receive(:delete)

      expect(service.remove_block(block)).to be(false)
    end

    it "restores the item when the row is re-blocked between the check and the delete" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "raced@example.com")
      block.update_columns(blocked_at: nil, expires_at: nil)
      stub_item("raced@example.com", "rsli_9")

      # Commits the re-block after remove_block has already passed its reload check, which is the
      # only window where a delete can strip Radar enforcement from a live block.
      allow(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_9") do
        PlatformBlock.find(block.id).update_columns(blocked_at: Time.current)
      end

      expect(Stripe::Radar::ValueListItem).to receive(:create).with(
        value_list: "rsl_123",
        value: "raced@example.com"
      )

      expect(service.remove_block(block)).to be(false)
    end

    it "does not re-add the item when no concurrent re-block happened" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "clean@example.com")
      block.update_columns(blocked_at: nil, expires_at: nil)
      stub_item("clean@example.com", "rsli_10")
      allow(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_10")

      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      expect(service.remove_block(block)).to be(true)
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

  describe "#add_block" do
    before do
      allow(Stripe::Radar::ValueList).to receive(:list).and_return(double(data: [value_list]))
      allow(Stripe::Radar::ValueListItem).to receive(:list).and_return(double(data: []))
    end

    it "pushes a newly blocked email to Radar without waiting for the daily window" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "fresh@example.com")

      expect(Stripe::Radar::ValueListItem).to receive(:create).with(value_list: "rsl_123", value: "fresh@example.com")

      expect(service.add_block(block)).to be(true)
    end

    # The converse of the removal race, and the reason remove_block's final check does not need a
    # lock: an unblock committing after add_block's reload would otherwise leave a live Radar item
    # rejecting a buyer who is no longer blocked, until tomorrow's sync.
    it "removes the item when the row is unblocked between the check and the create" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "raced-add@example.com")
      allow(Stripe::Radar::ValueListItem).to receive(:list)
        .with(value_list: "rsl_123", value: "raced-add@example.com")
        .and_return(double(data: [double("ValueListItem", id: "rsli_20")]))

      allow(Stripe::Radar::ValueListItem).to receive(:create) do
        PlatformBlock.find(block.id).update_columns(blocked_at: nil, expires_at: nil)
      end

      expect(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_20")

      expect(service.add_block(block)).to be(false)
    end

    it "does not remove the item when no concurrent unblock happened" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "clean-add@example.com")
      allow(Stripe::Radar::ValueListItem).to receive(:create)

      expect(Stripe::Radar::ValueListItem).not_to receive(:delete)

      expect(service.add_block(block)).to be(true)
    end

    it "skips a row already cleared before the job ran" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "already-clear@example.com")
      PlatformBlock.find(block.id).update_columns(blocked_at: nil, expires_at: nil)

      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      expect(service.add_block(block)).to be(false)
    end

    it "skips types that are never pushed to Radar" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "157.45.09.214", expires_in: 1.hour)

      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      expect(service.add_block(block)).to be(false)
    end

    it "skips fingerprints the daily job's filter would have rejected" do
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "not a fingerprint")

      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      expect(service.add_block(block)).to be(false)
    end
  end

  describe "add loop re-check" do
    before do
      allow(Stripe::Radar::ValueList).to receive(:list).and_return(double(data: [value_list]))
      allow(Stripe::Radar::ValueListItem).to receive(:list).and_return(double(data: []))
    end

    it "does not re-add an email cleared after the sync's SELECT" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "cleared-mid-sync@example.com")
      allow_any_instance_of(PlatformBlock).to receive(:reload) do |record|
        record.assign_attributes(blocked_at: nil)
        record
      end

      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      service.sync_blocked_emails
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
