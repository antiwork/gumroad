# frozen_string_literal: true

require "spec_helper"

describe Iffy::Product::IngestJob do
  describe "#perform" do
    let(:product) { create(:product) }

    it "invokes the ingest service with the correct product" do
      expect(Iffy::Product::IngestService).to receive(:new).with(product).and_call_original
      expect_any_instance_of(Iffy::Product::IngestService).to receive(:perform)

      Iffy::Product::IngestJob.new.perform(product.id)
    end
  end
end
