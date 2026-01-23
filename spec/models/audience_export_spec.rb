# frozen_string_literal: true

require "spec_helper"

RSpec.describe AudienceExport do
  describe "validations" do
    it "requires at least one audience type to be selected" do
      export = build(:audience_export, followers: false, customers: false, affiliates: false)
      expect(export).not_to be_valid
      expect(export.errors[:base]).to include("At least one audience type (followers, customers, or affiliates) must be selected")
    end

    it "is valid with followers selected" do
      export = build(:audience_export, followers: true, customers: false, affiliates: false)
      expect(export).to be_valid
    end

    it "is valid with customers selected" do
      export = build(:audience_export, followers: false, customers: true, affiliates: false)
      expect(export).to be_valid
    end

    it "is valid with affiliates selected" do
      export = build(:audience_export, followers: false, customers: false, affiliates: true)
      expect(export).to be_valid
    end

    it "is valid with multiple audience types selected" do
      export = build(:audience_export, followers: true, customers: true, affiliates: true)
      expect(export).to be_valid
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

    it "has many audience_export_chunks" do
      export = create(:audience_export)
      chunk1 = create(:audience_export_chunk, audience_export: export)
      chunk2 = create(:audience_export_chunk, audience_export: export)
      expect(export.audience_export_chunks).to contain_exactly(chunk1, chunk2)
    end
  end

  describe "#destroy" do
    it "deletes associated chunks" do
      export = create(:audience_export)
      create(:audience_export_chunk, audience_export: export)
      create(:audience_export_chunk, audience_export: export)
      expect(AudienceExportChunk.count).to eq(2)

      export.destroy!

      expect(AudienceExportChunk.count).to eq(0)
    end
  end

  describe "json_data accessors" do
    it "stores and retrieves followers" do
      export = create(:audience_export, followers: true)
      export.reload
      expect(export.followers).to eq(true)
    end

    it "stores and retrieves customers" do
      export = create(:audience_export, customers: true)
      export.reload
      expect(export.customers).to eq(true)
    end

    it "stores and retrieves affiliates" do
      export = create(:audience_export, affiliates: true)
      export.reload
      expect(export.affiliates).to eq(true)
    end

    it "defaults to false when not set" do
      export = create(:audience_export, followers: true)
      export.reload
      expect(export.customers).to eq(false)
      expect(export.affiliates).to eq(false)
    end
  end
end
