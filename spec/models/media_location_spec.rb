# frozen_string_literal: true

require "spec_helper"

describe MediaLocation do
  describe "#create" do
    before do
      @product = create(:product)
      purchase = create(:free_purchase, link: @product)
      @url_redirect = create(:url_redirect, link: @product, purchase:)
      create(:readable_document, link: @product)
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

      it "infers percentage units for an EPUB" do
        epub = create(:epub_product_file, link: @product)
        media_location = build(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                                product_file_id: epub.id, product_id: @product.id, location: 42,
                                                epub_cfi: "epubcfi(/6/4!/4/2/8:0)")

        media_location.save!

        expect(media_location.unit).to eq MediaLocation::Unit::PERCENTAGE
      end

      it "validates the EPUB CFI shape and storage bound" do
        epub = create(:epub_product_file, link: @product)
        media_location = build(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                                product_file_id: epub.id, product_id: @product.id, location: 42)

        [
          "not-a-cfi",
          "epubcfi(foo)",
          "epubcfi(/6/4!)",
          "epubcfi(/6/4[#{"^" * 501}]!/4)",
          "epubcfi(#{"a" * MediaLocation::MAX_EPUB_CFI_LENGTH})",
        ].each do |epub_cfi|
          media_location.epub_cfi = epub_cfi
          expect(media_location).not_to be_valid
        end

        media_location.epub_cfi = "epubcfi(/6/4[chapter^]one]!/4/2:0)"
        expect(media_location).to be_valid
      end

      it "validates EPUB progress as a percentage" do
        epub = create(:epub_product_file, link: @product)
        media_location = build(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                                product_file_id: epub.id, product_id: @product.id, location: -1,
                                                epub_cfi: "epubcfi(/6/4!/4/2/8:0)")

        expect(media_location).not_to be_valid
        media_location.location = 101
        expect(media_location).not_to be_valid
      end

      it "keeps page-number units for a legacy EPUB location without a CFI" do
        epub = create(:epub_product_file, link: @product)
        media_location = build(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                                product_file_id: epub.id, product_id: @product.id, location: 4)

        media_location.save!

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
      purchase = create(:free_purchase, link: product)
      product_files = create_list(:product_file, 2, link: product)
      url_redirect = create(:url_redirect, link: product, purchase:)
      media_location_attributes = { purchase:, product_id: product.id, url_redirect_id: url_redirect.id }
      expected = []
      expected << create(:media_location, **media_location_attributes, product_file: product_files[0], consumed_at: 3.days.ago) # most recent for file
      create(:media_location, **media_location_attributes, product_file: product_files[0], consumed_at: 7.days.ago)
      create(:media_location, **media_location_attributes, product_file: product_files[1], consumed_at: 5.days.ago)
      expected << create(:media_location, **media_location_attributes, product_file: product_files[1], consumed_at: 2.days.ago) # most recent for file

      other_purchase = create(:free_purchase, link: product)
      other_url_redirect = create(:url_redirect, link: product, purchase: other_purchase)
      create(:media_location, purchase: other_purchase, product_id: product.id, url_redirect_id: other_url_redirect.id,
                              product_file: product_files[0], consumed_at: 1.day.ago)

      expect(MediaLocation.max_consumed_at_by_file(purchase_id: purchase.id)).to match_array(expected)
    end
  end

  describe ".max_consumed_at_by_file_for_purchases" do
    it "returns the most recent record per (purchase, product_file) pair across all given purchases in one query" do
      product = create(:product)
      purchase_1 = create(:purchase, link: product)
      purchase_2 = create(:purchase, link: product)
      product_files = create_list(:product_file, 2, link: product)

      expected = []
      expected << create(:media_location, purchase: purchase_1, product_file: product_files[0], consumed_at: 3.days.ago)
      create(:media_location, purchase: purchase_1, product_file: product_files[0], consumed_at: 7.days.ago)
      expected << create(:media_location, purchase: purchase_1, product_file: product_files[1], consumed_at: 2.days.ago)
      expected << create(:media_location, purchase: purchase_2, product_file: product_files[0], consumed_at: 1.day.ago)
      create(:media_location, purchase: purchase_2, product_file: product_files[0], consumed_at: 4.days.ago)
      create(:media_location, product_file: product_files[0], consumed_at: 1.hour.ago) # unrelated purchase

      result = MediaLocation.max_consumed_at_by_file_for_purchases(purchase_ids: [purchase_1.id, purchase_2.id])
      expect(result).to match_array(expected)
    end

    it "matches max_consumed_at_by_file for each purchase individually" do
      product = create(:product)
      purchases = create_list(:purchase, 2, link: product)
      product_file = create(:product_file, link: product)
      purchases.each do |purchase|
        create(:media_location, purchase:, product_file:, consumed_at: 2.days.ago)
        create(:media_location, purchase:, product_file:, consumed_at: 1.day.ago)
      end

      batched = MediaLocation.max_consumed_at_by_file_for_purchases(purchase_ids: purchases.map(&:id)).group_by(&:purchase_id)
      purchases.each do |purchase|
        expect(batched[purchase.id]).to match_array(MediaLocation.max_consumed_at_by_file(purchase_id: purchase.id))
      end
    end
  end
end
