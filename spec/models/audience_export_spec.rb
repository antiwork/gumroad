# frozen_string_literal: true

require "spec_helper"

RSpec.describe AudienceExport do
  describe "#destroy" do
    it "deletes chunks" do
      export = create(:audience_export)
      create(:audience_export_chunk, export:)
      expect(AudienceExportChunk.count).to eq(1)
      export.destroy!
      expect(AudienceExportChunk.count).to eq(0)
    end
  end

  describe "validations" do
    it "requires audience_options" do
      export = build(:audience_export, audience_options: nil)
      expect(export).not_to be_valid
      expect(export.errors[:audience_options]).to be_present
    end
  end
end
