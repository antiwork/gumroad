# frozen_string_literal: true

require "spec_helper"

describe MediaLocationsController do
  describe "POST create" do
    before do
      @product = create(:product)
      @product_file = create(:product_file, link: @product)
      @purchase = create(:free_purchase, link: @product)
      @url_redirect = create(:url_redirect, purchase: @purchase)
    end

    it "successfully creates media_location" do
      params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "web",
        consumed_at: "2015-09-10T00:26:50.000Z",
        location: 1,
      }

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(true)
      media_location = MediaLocation.last
      expect(media_location.product_file_id).to be(@product_file.id)
      expect(media_location.url_redirect_id).to be(@url_redirect.id)
      expect(media_location.purchase_id).to be(@purchase.id)
      expect(media_location.product_id).to be(@product.id)
      expect(media_location.platform).to eq(params[:platform])
      expect(media_location.location).to eq(params[:location])
      expect(media_location.unit).to eq MediaLocation::Unit::PAGE_NUMBER
      expect(media_location.consumed_at).to eq(params[:consumed_at])
    end

    it "stores percentage progress and a CFI for an EPUB" do
      product_file = create(:epub_product_file, link: @product)
      params = {
        product_file_id: product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "web",
        consumed_at: "2015-09-10T00:26:50.000Z",
        location: 42,
        epub_cfi: "epubcfi(/6/4!/4/2/8:0)",
      }

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(true)
      media_location = MediaLocation.last
      expect(media_location.location).to eq(42)
      expect(media_location.epub_cfi).to eq(params[:epub_cfi])
      expect(media_location.unit).to eq(MediaLocation::Unit::PERCENTAGE)
      expect(media_location.as_json[:cfi]).to eq(params[:epub_cfi])
    end

    it "rejects malformed or oversized EPUB CFIs without raising" do
      product_file = create(:epub_product_file, link: @product)
      base_params = {
        product_file_id: product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "web",
        location: 42,
      }

      [
        "not-a-cfi",
        "epubcfi(foo)",
        "epubcfi(/6/4!)",
        "epubcfi(#{"a" * MediaLocation::MAX_EPUB_CFI_LENGTH})",
      ].each do |epub_cfi|
        post(:create, params: base_params.merge(epub_cfi:))
        expect(response.parsed_body["success"]).to be(false)
      end
      expect(MediaLocation.where(product_file:)).to be_empty
    end

    it "rejects EPUB progress outside the percentage range" do
      product_file = create(:epub_product_file, link: @product)
      base_params = {
        product_file_id: product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "web",
        epub_cfi: "epubcfi(/6/4!/4/2/8:0)",
      }

      [-1, 101].each do |location|
        post(:create, params: base_params.merge(location:))
        expect(response.parsed_body["success"]).to be(false)
      end
      expect(MediaLocation.where(product_file:)).to be_empty
    end

    it "does not store an EPUB CFI for another file type" do
      params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "web",
        location: 1,
        epub_cfi: "epubcfi(/6/4!/4/2/8:0)",
      }

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(true)
      expect(MediaLocation.last.epub_cfi).to be_nil
    end

    it "uses the url_redirect's purchase id if one is not provided" do
      params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        platform: "android",
        location: 1,
      }

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(true)
      media_location = MediaLocation.last
      expect(media_location.purchase_id).to be(@purchase.id)
    end

    it "creates a media_location with consumed_at set to the current_time now if one is not provided" do
      params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        location: 1,
      }
      travel_to Time.current

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(true)
      media_location = MediaLocation.last
      expect(media_location.consumed_at).to eq(Time.current.to_json) # to_json so it only has second precision
    end

    context "avoid creating new media_location if valid existing media_location is present" do
      it "updates existing media_location instead of creating a new one if it exists" do
        MediaLocation.create!(product_file_id: @product_file.id, product_id: @product.id, url_redirect_id: @url_redirect.id,
                              purchase_id: @purchase.id, platform: "web", consumed_at: "2015-09-10T00:26:50.000Z", location: 1)
        expect(MediaLocation.count).to eq 1
        params = {
          product_file_id: @product_file.external_id,
          url_redirect_id: @url_redirect.external_id,
          platform: "web",
          location: 2,
        }

        post(:create, params:)

        expect(MediaLocation.count).to eq 1
        expect(response.parsed_body["success"]).to be(true)
        media_location = MediaLocation.last
        expect(media_location.location).to eq(params[:location])
      end

      it "updates the unit and CFI when the existing product file changes type" do
        media_location = MediaLocation.create!(product_file_id: @product_file.id, product_id: @product.id,
                                               url_redirect_id: @url_redirect.id, purchase_id: @purchase.id,
                                               platform: "web", consumed_at: 1.day.ago, location: 1)
        expect(media_location.unit).to eq(MediaLocation::Unit::PAGE_NUMBER)
        @product_file.update!(filetype: "epub", filegroup: "epub_document", url: "#{S3_BASE_URL}specs/test.epub")

        post(:create, params: {
               product_file_id: @product_file.external_id,
               url_redirect_id: @url_redirect.external_id,
               purchase_id: @purchase.external_id,
               platform: "web",
               consumed_at: 2.hours.ago.iso8601(6),
               location: 42,
               epub_cfi: "epubcfi(/6/4!/4/2/8:0)",
             })

        expect(response.parsed_body["success"]).to be(true)
        expect(media_location.reload.unit).to eq(MediaLocation::Unit::PERCENTAGE)
        expect(media_location.epub_cfi).to eq("epubcfi(/6/4!/4/2/8:0)")

        @product_file.update!(filetype: "pdf", filegroup: "document", url: "#{S3_BASE_URL}specs/test.pdf")
        post(:create, params: {
               product_file_id: @product_file.external_id,
               url_redirect_id: @url_redirect.external_id,
               purchase_id: @purchase.external_id,
               platform: "web",
               consumed_at: 1.hour.ago.iso8601(6),
               location: 3,
             })

        expect(response.parsed_body["success"]).to be(true)
        expect(media_location.reload.unit).to eq(MediaLocation::Unit::PAGE_NUMBER)
        expect(media_location.epub_cfi).to be_nil
      end

      it "creates new media_location if existing media_location is present but on different platform" do
        MediaLocation.create!(product_file_id: @product_file.id, product_id: @product.id, url_redirect_id: @url_redirect.id,
                              purchase_id: @purchase.id, platform: "web", consumed_at: "2015-09-10T00:26:50.000Z", location: 1)
        expect(MediaLocation.count).to eq 1
        params = {
          product_file_id: @product_file.external_id,
          url_redirect_id: @url_redirect.external_id,
          platform: "android",
          location: 2,
        }

        post(:create, params:)

        expect(MediaLocation.count).to eq 2
        expect(response.parsed_body["success"]).to be(true)
      end
    end

    it "ignores creating media locations for non consumable files" do
      @product_file = create(:non_readable_document, link: @product)
      params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "web",
        consumed_at: "2015-09-10T00:26:50.000Z",
        location: 1,
      }

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(false)
    end

    it "does not update media location if event is older than the one in db" do
      MediaLocation.create!(product_file_id: @product_file.id, product_id: @product.id, url_redirect_id: @url_redirect.id,
                            purchase_id: @purchase.id, platform: "web", consumed_at: "2015-09-10T00:26:50.000Z", location: 1)
      params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "web",
        consumed_at: "2015-09-10T00:24:50.000Z",
        location: 1,
      }

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(false)
      expect(MediaLocation.count).to eq(1)
      expect(MediaLocation.first.location).to eq(1)
    end

    it "updates media location if event is newer than the one in db" do
      MediaLocation.create!(product_file_id: @product_file.id, product_id: @product.id, url_redirect_id: @url_redirect.id,
                            purchase_id: @purchase.id, platform: "web", consumed_at: "2015-09-10T00:26:50.000Z", location: 1)
      params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "web",
        consumed_at: "2015-09-10T00:28:50.000Z",
        location: 2,
      }

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(true)
      expect(MediaLocation.count).to eq(1)
      expect(MediaLocation.first.location).to eq(2)
    end
  end
end
