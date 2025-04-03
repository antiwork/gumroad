# frozen_string_literal: true

require "spec_helper"

RSpec.describe SalesExportChunk do
  it "can be created" do
    create(:sales_export_chunk)
  end
end
