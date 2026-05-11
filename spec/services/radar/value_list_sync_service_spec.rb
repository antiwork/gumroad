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
    end

    it "pushes recently blocked emails to Stripe Radar" do
      blocked_email = BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "bad@example.com", nil)

      expect(Stripe::Radar::ValueListItem).to receive(:create).with(
        value_list: "rsl_123",
        value: "bad@example.com"
      )

      service.sync_blocked_emails
    end

    it "skips emails blocked more than a day ago" do
      travel_to 2.days.ago do
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "old@example.com", nil)
      end

      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      service.sync_blocked_emails
    end

    it "creates the value list if it does not exist" do
      allow(Stripe::Radar::ValueList).to receive(:retrieve)
        .with("gumroad_blocked_emails")
        .and_raise(Stripe::InvalidRequestError.new("No such value list", "alias"))

      expect(Stripe::Radar::ValueList).to receive(:create).with(
        alias: "gumroad_blocked_emails",
        name: "Gumroad Blocked Emails",
        item_type: "email"
      ).and_return(value_list)

      service.sync_blocked_emails
    end

    it "ignores duplicate item errors" do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "dup@example.com", nil)

      allow(Stripe::Radar::ValueListItem).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("This value already exists", "value"))

      expect { service.sync_blocked_emails }.not_to raise_error
    end
  end

  describe "#sync_blocked_cards" do
    before do
      allow(Stripe::Radar::ValueList).to receive(:retrieve)
        .with("gumroad_blocked_cards")
        .and_return(value_list)
    end

    it "pushes recently blocked card fingerprints to Stripe Radar" do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], "fp_abc123", nil)

      expect(Stripe::Radar::ValueListItem).to receive(:create).with(
        value_list: "rsl_123",
        value: "fp_abc123"
      )

      service.sync_blocked_cards
    end

    it "skips fingerprints blocked more than a day ago" do
      travel_to 2.days.ago do
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], "fp_old", nil)
      end

      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      service.sync_blocked_cards
    end

    it "ignores duplicate item errors" do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], "fp_dup", nil)

      allow(Stripe::Radar::ValueListItem).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("This value already exists", "value"))

      expect { service.sync_blocked_cards }.not_to raise_error
    end
  end
end
