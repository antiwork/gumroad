# frozen_string_literal: true

require "spec_helper"

RSpec.describe SalesExport do
  describe "#destroy" do
    it "deletes chunks" do
      export = create(:sales_export)
      create(:sales_export_chunk, export:)
      expect(SalesExportChunk.count).to eq(1)
      export.destroy!
      expect(SalesExportChunk.count).to eq(0)
    end
  end
end
