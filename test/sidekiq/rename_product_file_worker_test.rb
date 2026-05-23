# frozen_string_literal: true

require "test_helper"

class RenameProductFileWorkerTest < ActiveSupport::TestCase
  self.described_class = RenameProductFileWorker



  context_ RenameProductFileWorker do
    before do
      @product_file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
    end

  context_ "#perform" do
  context_ "when file is present in CDN" do
  test "renames the file" do
          expect_any_instance_of(ProductFile).to receive(:rename_in_storage)

          described_class.new.perform(@product_file.id)
        end
      end

  context_ "when file is deleted from CDN" do
  test "doesn't rename the file" do
          @product_file.mark_deleted_from_cdn
          expect_any_instance_of(ProductFile).not_to receive(:rename_in_storage)

          described_class.new.perform(@product_file.id)
        end
      end
    end
  end
end
