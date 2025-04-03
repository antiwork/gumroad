# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::MediaLocationsController do
  describe "POST create" do
    before do
      @user = create(:user)
      @purchaser = create(:user)
      @url_redirect = create(:readable_url_redirect, link: create(:product, user: @user), purchase: create(:purchase, purchaser: @purchaser))
      @purchase = @url_redirect.purchase
      @product = @url_redirect.referenced_link
      @product_file = @product.product_files.first
      @app = create(:oauth_application, owner: @user)
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @purchaser.id, scopes: "mobile_api")
      @mobile_post_params = { id: @purchase.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: @token.token }
    end

    it "successfully creates media_location" do
      media_location_params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        consumed_at: "2015-09-09T17:26:50PDT",
        location: 1,
      }

      post :create, params: @mobile_post_params.merge(media_location_params)

      expect(response.parsed_body["success"]).to be(true)
      media_location = MediaLocation.last
      expect(media_location.product_file_id).to be(@product_file.id)
      expect(media_location.url_redirect_id).to be(@url_redirect.id)
      expect(media_location.purchase_id).to be(@purchase.id)
      expect(media_location.product_id).to be(@product.id)
      expect(media_location.platform).to eq(media_location_params[:platform])
      expect(media_location.location).to eq(media_location_params[:location])
      expect(media_location.unit).to eq MediaLocation::Unit::PAGE_NUMBER
      expect(media_location.consumed_at).to eq(media_location_params[:consumed_at])
    end

    it "fails to create consumption event if access token is invalid" do
      @mobile_post_params[:access_token] = "invalid_token"
      media_location_params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        consumed_at: "2015-09-09T17:26:50PDT",
        location: 1,
      }

      post :create, params: @mobile_post_params.merge(media_location_params)

      expect(response.status).to be(401)
      expect(MediaLocation.all.count).to eq(0)
    end

    it "fails to create consumption event if mobile token is invalid" do
      @mobile_post_params[:mobile_token] = "invalid_token"
      media_location_params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        consumed_at: "2015-09-09T17:26:50PDT",
        location: 1,
      }

      post :create, params: @mobile_post_params.merge(media_location_params)

      expect(response.status).to be(401)
      expect(MediaLocation.all.count).to eq(0)
    end

    it "uses the url_redirect's purchase id if one is not provided" do
      media_location_params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        platform: "android",
        location: 1,
      }

      post :create, params: @mobile_post_params.merge(media_location_params)

      expect(response.parsed_body["success"]).to be(true)
      media_location = MediaLocation.last
      expect(media_location.purchase_id).to be(@purchase.id)
    end

    it "creates a media_location with consumed_at set to the current_time now if one is not provided" do
      media_location_params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        location: 1,
      }
      travel_to Time.current

      post :create, params: @mobile_post_params.merge(media_location_params)

      expect(response.parsed_body["success"]).to be(true)
      media_location = MediaLocation.last
      expect(media_location.consumed_at).to eq(Time.current.to_json) # to_json so it only has second precision
    end

    context "avoid creating new media_location if valid existing media_location is present" do
      it "updates existing media_location instead of creating a new one if it exists" do
        MediaLocation.create!(product_file_id: @product_file.id, product_id: @product.id, url_redirect_id: @url_redirect.id,
                              purchase_id: @purchase.id, platform: "android", consumed_at: "2015-09-09T17:26:50PDT", location: 1)
        expect(MediaLocation.count).to eq 1
        media_location_params = {
          product_file_id: @product_file.external_id,
          url_redirect_id: @url_redirect.external_id,
          platform: "android",
          location: 2,
        }

        post :create, params: @mobile_post_params.merge(media_location_params)

        expect(MediaLocation.count).to eq 1
        expect(response.parsed_body["success"]).to be(true)
        media_location = MediaLocation.last
        expect(media_location.location).to eq(media_location_params[:location])
      end

      it "creates new media_location if existing media_location is present but on different platform" do
        MediaLocation.create!(product_file_id: @product_file.id, product_id: @product.id, url_redirect_id: @url_redirect.id,
                              purchase_id: @purchase.id, platform: "web", consumed_at: "2015-09-09T17:26:50PDT", location: 1)
        expect(MediaLocation.count).to eq 1
        media_location_params = {
          product_file_id: @product_file.external_id,
          url_redirect_id: @url_redirect.external_id,
          platform: "android",
          location: 2,
        }

        post :create, params: @mobile_post_params.merge(media_location_params)

        expect(MediaLocation.count).to eq 2
        expect(response.parsed_body["success"]).to be(true)
      end
    end

    it "ignores creating media locations for non consumable files" do
      @product_file = create(:non_readable_document, link: @product)
      media_location_params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        consumed_at: "2015-09-09T17:26:50PDT",
        location: 1,
      }

      post :create, params: @mobile_post_params.merge(media_location_params)

      expect(response.parsed_body["success"]).to be(false)
    end

    it "does not update media location if event is older than the one in db" do
      MediaLocation.create!(product_file_id: @product_file.id, product_id: @product.id, url_redirect_id: @url_redirect.id,
                            purchase_id: @purchase.id, platform: "android", consumed_at: "2015-09-09T17:26:50PDT", location: 1)
      params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        consumed_at: "2015-09-09T17:24:50PDT",
        location: 1,
      }

      post :create, params: @mobile_post_params.merge(params)

      expect(response.parsed_body["success"]).to be(false)
      expect(MediaLocation.count).to eq(1)
      expect(MediaLocation.first.location).to eq(1)
    end

    it "updates media location if event is newer than the one in db" do
      MediaLocation.create!(product_file_id: @product_file.id, product_id: @product.id, url_redirect_id: @url_redirect.id,
                            purchase_id: @purchase.id, platform: "android", consumed_at: "2015-09-09T17:26:50PDT", location: 1)
      params = {
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        consumed_at: "2015-09-09T17:28:50PDT",
        location: 2,
      }

      post :create, params: @mobile_post_params.merge(params)

      expect(response.parsed_body["success"]).to be(true)
      expect(MediaLocation.count).to eq(1)
      expect(MediaLocation.first.location).to eq(2)
    end
  end
end
