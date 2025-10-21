# frozen_string_literal: true

require "spec_helper"

describe RenameProductFileWorker do
  before do
    @product_file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
  end

  describe "#perform" do
    context "when file is present in CDN" do
      it "renames the file" do
        expect_any_instance_of(ProductFile).to receive(:rename_in_storage)

        described_class.new.perform(@product_file.id)
      end
    end

    context "when file is deleted from CDN" do
      it "doesn't rename the file" do
        @product_file.mark_deleted_from_cdn
        expect_any_instance_of(ProductFile).not_to receive(:rename_in_storage)

        described_class.new.perform(@product_file.id)
      end
    end
  end
end
