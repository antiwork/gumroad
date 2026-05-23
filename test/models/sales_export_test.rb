# frozen_string_literal: true

require "test_helper"

class SalesExportTest < ActiveSupport::TestCase
  self.described_class = SalesExport



  context_ SalesExport do
  context_ "#destroy" do
  test "deletes chunks" do
        export = create(:sales_export)
        create(:sales_export_chunk, export:)
        expect(SalesExportChunk.count).to eq(1)
        export.destroy!
        expect(SalesExportChunk.count).to eq(0)
      end
    end
  end
end
