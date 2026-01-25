# frozen_string_literal: true

require "spec_helper"

describe Exports::Audience::CompileChunksWorker do
  let(:mock_mail) { double("mail", deliver_now: true) }

  before do
    @worker = described_class.new
    # Check the tests of AudienceController#export for the complete overall behavior,
    # what the email sent contains, etc.
    @csv_tempfile = Tempfile.new
    allow(@worker).to receive(:generate_compiled_tempfile).and_return(@csv_tempfile)
    @export = create(:audience_export)
    create(:audience_export_chunk, export: @export)
    # Stub mailer to avoid Shakapacker/webpack dependency in test environment
    allow(ContactingCreatorMailer).to receive(:subscribers_data).and_return(mock_mail)
  end

  it "sends email" do
    expect(ContactingCreatorMailer).to receive(:subscribers_data).with(
      recipient: @export.recipient,
      tempfile: @csv_tempfile,
      filename: anything
    ).and_return(mock_mail)
    @worker.perform(@export.id)
  end

  it "destroys export and chunks" do
    @worker.perform(@export.id)
    expect(AudienceExport.count).to eq(0)
    expect(AudienceExportChunk.count).to eq(0)
  end
end
