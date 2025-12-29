# frozen_string_literal: true

require "spec_helper"

RSpec.describe AudienceExport do
  describe "validations" do
    it "requires audience_options" do
      export = build(:audience_export, audience_options: nil)
      expect(export).not_to be_valid
      expect(export.errors[:audience_options]).to include("can't be blank")
    end

    it "requires external_id to be unique" do
      existing = create(:audience_export)
      duplicate = build(:audience_export)
      duplicate.external_id = existing.external_id
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:external_id]).to include("has already been taken")
    end
  end

  describe "external_id generation" do
    it "generates external_id on create" do
      export = create(:audience_export)
      expect(export.external_id).to be_present
      expect(export.external_id.length).to eq(12)
    end

    it "generates unique external_ids" do
      export1 = create(:audience_export)
      export2 = create(:audience_export)
      expect(export1.external_id).not_to eq(export2.external_id)
    end

    it "does not overwrite existing external_id" do
      export = build(:audience_export)
      export.external_id = "custom123456"
      export.save!
      expect(export.external_id).to eq("custom123456")
    end
  end

  describe "associations" do
    it "belongs to seller" do
      seller = create(:user)
      export = create(:audience_export, seller: seller)
      expect(export.seller).to eq(seller)
    end

    it "belongs to recipient" do
      recipient = create(:user)
      export = create(:audience_export, recipient: recipient)
      expect(export.recipient).to eq(recipient)
    end

    it "has many chunks" do
      export = create(:audience_export)
      chunk1 = create(:audience_export_chunk, export: export)
      chunk2 = create(:audience_export_chunk, export: export)
      expect(export.chunks).to contain_exactly(chunk1, chunk2)
    end
  end

  describe "#destroy" do
    it "deletes associated chunks" do
      export = create(:audience_export)
      create(:audience_export_chunk, export: export)
      create(:audience_export_chunk, export: export)
      expect(AudienceExportChunk.count).to eq(2)

      export.destroy!

      expect(AudienceExportChunk.count).to eq(0)
    end
  end

  describe "serialization" do
    it "serializes audience_options as Hash" do
      options = { "followers" => true, "customers" => false, "affiliates" => true }
      export = create(:audience_export, audience_options: options)
      export.reload
      expect(export.audience_options).to eq(options)
    end
  end
end
