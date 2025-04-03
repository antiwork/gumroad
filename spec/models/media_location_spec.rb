# frozen_string_literal: true

require "spec_helper"

describe MediaLocation do
  describe "#create" do
    before do
      @url_redirect = create(:readable_url_redirect)
      @product = @url_redirect.referenced_link
    end

    it "raises error if platform is invalid" do
      media_location = build(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                              product_file_id: @product.product_files.first.id,
                                              product_id: @product.id, location: 1)
      media_location.platform = "invalid_platform"
      media_location.validate
      expect(media_location.errors.full_messages).to include("Platform is not included in the list")
    end

    it "raises error if product file is not consumable" do
      non_consumable_file = create(:non_readable_document, link: @product)
      media_location = build(:media_location, product_file_id: non_consumable_file.id, product_id: @product.id,
                                              url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                              location: 1)
      media_location.validate
      expect(media_location.errors[:base]).to include("File should be consumable")
    end

    context "inferring units from file type" do
      it "infers correct units for readable" do
        media_location = build(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                                product_file_id: @product.product_files.first.id,
                                                product_id: @product.id, location: 1)
        media_location.save
        expect(media_location.unit).to eq MediaLocation::Unit::PAGE_NUMBER
      end

      it "infers correct units for streamable" do
        streamable = create(:streamable_video, link: @product)
        media_location = build(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                                product_file_id: streamable.id,
                                                product_id: @product.id, location: 1)
        media_location.save
        expect(media_location.unit).to eq MediaLocation::Unit::SECONDS
      end

      it "infers correct units for listenable" do
        listenable = create(:listenable_audio, link: @product)
        media_location = build(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                                product_file_id: listenable.id,
                                                product_id: @product.id, location: 1)
        media_location.save
        expect(media_location.unit).to eq MediaLocation::Unit::SECONDS
      end
    end
  end

  describe ".max_consumed_at_by_file" do
    it "returns the records with the largest consumed_at value for each product_file" do
      product = create(:product)
      purchase = create(:purchase, link: product)
      product_files = create_list(:product_file, 2, link: product)
      expected = []
      expected << create(:media_location, purchase:, product_file: product_files[0], consumed_at: 3.days.ago) # most recent for file
      create(:media_location, purchase:, product_file: product_files[0], consumed_at: 7.days.ago)
      create(:media_location, purchase:, product_file: product_files[1], consumed_at: 5.days.ago)
      expected << create(:media_location, purchase:, product_file: product_files[1], consumed_at: 2.days.ago) # most recent for file
      create(:media_location, product_file: product_files[0], consumed_at: 1.day.ago) # different purchase

      expect(MediaLocation.max_consumed_at_by_file(purchase_id: purchase.id)).to match_array(expected)
    end
  end
end
