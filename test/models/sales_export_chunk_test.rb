# frozen_string_literal: true

require "test_helper"

class SalesExportChunkTest < ActiveSupport::TestCase
  self.described_class = SalesExportChunk



  context_ SalesExportChunk do
  test "can be created" do
      create(:sales_export_chunk)
    end
  end
end
