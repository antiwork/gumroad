# frozen_string_literal: true

require "spec_helper"

describe Iffy::Post::IngestJob do
  describe "#perform" do
    let(:installment) { create(:installment) }

    it "invokes the ingest service with the correct installment" do
      expect(Iffy::Post::IngestService).to receive(:new).with(installment).and_call_original
      expect_any_instance_of(Iffy::Post::IngestService).to receive(:perform)

      Iffy::Post::IngestJob.new.perform(installment.id)
    end
  end
end
