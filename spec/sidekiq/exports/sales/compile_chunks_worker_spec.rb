# frozen_string_literal: true

require "spec_helper"

describe Exports::Sales::CompileChunksWorker do
  before do
    @worker = described_class.new
    # Check the tests of UsersController#export_sales for the complete overall behavior,
    # what the email sent contains, with which custom fields, etc.
    @csv_tempfile = Tempfile.new
    allow(@worker).to receive(:generate_compiled_tempfile).and_return(@csv_tempfile)
    @export = create(:sales_export)
    create(:sales_export_chunk, export: @export)
  end

  it "sends email" do
    expect(ContactingCreatorMailer).to receive(:user_sales_data).with(@export.recipient_id, @csv_tempfile).and_call_original
    @worker.perform(@export.id)
  end

  it "destroys export and chunks" do
    @worker.perform(@export.id)
    expect(SalesExport.count).to eq(0)
    expect(SalesExportChunk.count).to eq(0)
  end
end
