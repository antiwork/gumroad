# frozen_string_literal: true

require "spec_helper"

describe DeleteProductFilesWorker do
  before do
    stub_const("PUBLIC_STORAGE_CDN_S3_PROXY_HOST", "#{AWS_S3_ENDPOINT}/#{PUBLIC_STORAGE_S3_BUCKET}")

    @image1 = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
    @image2 = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.jpg"), filename: "test.jpg")
    @image3 = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.jpeg"), filename: "test.jpeg")
    @product = create(:product, description: "<img src=\"#{@image1.url}\" />")
    @product_file_1 = create(:product_file, link: @product)
    @product_file_2 = create(:product_file, link: @product)
    create(:rich_content, entity: @product, description: [{ "type" => "image", "attrs" => { "src" => @image2.url, "link" => nil, class: nil } }])

    @product.delete!
  end

  describe "#perform" do
    it "deletes product files" do
      freeze_time do
        described_class.new.perform(@product.id)
      end
      expect([@product_file_1.reload.deleted?, @product_file_2.reload.deleted?]).to eq [true, true]
      expect(@product.product_files.alive.count).to eq 0
    end

    context "when there are successful purchases" do
      before do
        create(:purchase, link: @product, seller: @product.user)
        index_model_records(Purchase)
      end

      it "does not delete the product files" do
        freeze_time do
          described_class.new.perform(@product.id)
        end
        expect([@product_file_1.reload.deleted?, @product_file_2.reload.deleted?]).to eq [false, false]
        expect(@product.product_files.alive.count).to eq 2
      end
    end

    it "does not delete files if the product is not deleted" do
      @product.mark_undeleted!
      described_class.new.perform(@product.id)

      expect([@product_file_1.reload.deleted?, @product_file_2.reload.deleted?]).to eq [false, false]
      expect(@product.product_files.alive.count).to eq 2
    end
  end
end
