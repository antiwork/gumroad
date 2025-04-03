# frozen_string_literal: true

require "spec_helper"

describe Exports::Sales::ProcessChunkWorker do
  before do
    @worker = described_class.new
    # Check the tests of UsersController#export_sales for the complete overall behavior,
    # what the email sent contains, with which custom fields, etc.
    @csv_tempfile = Tempfile.new
    allow(@worker).to receive(:compile_chunks).and_return(@csv_tempfile)
    @export = create(:sales_export)
  end

  context "when there are still chunks to process" do
    before do
      create(:sales_export_chunk, export: @export)
      @chunk_2 = create(:sales_export_chunk, export: @export)
    end

    it "does not send email" do
      expect(ContactingCreatorMailer).not_to receive(:sales_data)
      @worker.perform(@chunk_2.id)
    end

    it "updates chunk" do
      @worker.perform(@chunk_2.id)
      @chunk_2.reload
      expect(@chunk_2.processed).to eq(true)
      expect(@chunk_2.revision).to eq(REVISION)
    end
  end

  context "when chunks were processed with another revision" do
    before do
      @chunk_1 = create(:sales_export_chunk, export: @export, processed: true, revision: "old-revision")
      @chunk_2 = create(:sales_export_chunk, export: @export)
    end

    it "does not send email" do
      expect(ContactingCreatorMailer).not_to receive(:sales_data)
      @worker.perform(@chunk_2.id)
    end

    it "updates chunk" do
      @worker.perform(@chunk_2.id)
      @chunk_2.reload
      expect(@chunk_2.processed).to eq(true)
      expect(@chunk_2.revision).to eq(REVISION)
    end

    it "requeues chunks that were processed with another revision" do
      @worker.perform(@chunk_2.id)
      expect(described_class).to have_enqueued_sidekiq_job(@chunk_1.id)
    end
  end
end
