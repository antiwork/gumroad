# frozen_string_literal: true

require "spec_helper"

describe Onetime::NormalizeBlockedCustomerObjectEmails do
  before do
    allow(ReplicaLagWatcher).to receive(:watch)
  end

  describe ".process" do
    it "normalizes dirty email block rows and buyer email values" do
      block = create(:blocked_customer_object, object_value: "buyer@example.com", buyer_email: "buyer@example.com")
      block.update_columns(object_value: "buyer\u00A0@example.com", buyer_email: "\u200Fbuyer@example.com")

      expect do
        expect(described_class.process(batch_size: 1)).to eq(1)
      end.to change { block.reload.object_value }.from("buyer\u00A0@example.com").to("buyer@example.com")
        .and change { block.reload.buyer_email }.from("\u200Fbuyer@example.com").to("buyer@example.com")
      expect(ReplicaLagWatcher).to have_received(:watch).at_least(:once)
    end

    it "leaves fingerprint object values untouched while normalizing their buyer email" do
      block = create(:blocked_customer_object, object_type: "charge_processor_fingerprint", object_value: "fingerprint", buyer_email: "buyer@example.com")
      block.update_column(:buyer_email, "buyer\u00A0@example.com")

      described_class.process

      expect(block.reload).to have_attributes(
        object_value: "fingerprint",
        buyer_email: "buyer@example.com"
      )
    end

    it "skips a degenerate email value instead of bypassing validation to write a blank" do
      block = create(:blocked_customer_object, object_value: "buyer@example.com", buyer_email: "buyer@example.com")
      block.update_columns(object_value: "\u200F", buyer_email: "\u00A0")

      expect(described_class.process).to eq(0)

      expect(block.reload).to have_attributes(
        object_value: "\u200F",
        buyer_email: "\u00A0"
      )
    end

    it "merges a dirty duplicate into the existing clean block instead of crashing on the unique index" do
      seller = create(:user)
      clean = create(:blocked_customer_object, seller:, object_value: "buyer@example.com", blocked_at: nil)
      dirty = create(:blocked_customer_object, seller:, object_value: "other@example.com", blocked_at: 2.days.ago)
      dirty.update_column(:object_value, "buyer\u00A0@example.com")

      expect do
        expect(described_class.process).to eq(1)
      end.to change { BlockedCustomerObject.exists?(dirty.id) }.from(true).to(false)

      expect(clean.reload.blocked_at.to_i).to eq(dirty.blocked_at.to_i)
      expect(BlockedCustomerObject.where(seller:, object_value: "buyer@example.com").count).to eq(1)
    end

    it "is idempotent after normalization" do
      block = create(:blocked_customer_object, object_value: "buyer@example.com")
      block.update_column(:object_value, "buyer\u00A0@example.com")

      expect(described_class.process).to eq(1)
      expect(described_class.process).to eq(0)
    end
  end
end
