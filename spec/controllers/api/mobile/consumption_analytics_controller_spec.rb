# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::ConsumptionAnalyticsController do
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
      @purchaseless_url_redirect = create(:readable_url_redirect, link: @product, purchase: nil)
    end

    it "successfully creates consumption event" do
      consumption_event_params = {
        event_type: "read",
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        consumed_at: "2015-09-09T17:26:50PDT"
      }

      post :create, params: @mobile_post_params.merge(consumption_event_params)

      expect(response.parsed_body["success"]).to be(true)
      event = ConsumptionEvent.last
      expect(event.event_type).to eq(consumption_event_params[:event_type])
      expect(event.product_file_id).to be(@product_file.id)
      expect(event.url_redirect_id).to be(@url_redirect.id)
      expect(event.purchase_id).to be(@purchase.id)
      expect(event.link_id).to be(@product.id)
      expect(event.platform).to eq(consumption_event_params[:platform])
      expect(event.consumed_at).to eq(consumption_event_params[:consumed_at])
    end

    it "fails to create consumption event if access token is invalid" do
      @mobile_post_params[:access_token] = "invalid_token"
      consumption_event_params = {
        event_type: "read",
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        consumed_at: "2015-09-09T17:26:50PDT"
      }

      post :create, params: @mobile_post_params.merge(consumption_event_params)

      expect(response.status).to be(401)
      expect(ConsumptionEvent.all.count).to eq(0)
    end

    it "fails to create consumption event if mobile token is invalid" do
      @mobile_post_params[:mobile_token] = "invalid_token"
      consumption_event_params = {
        event_type: "read",
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        consumed_at: "2015-09-09T17:26:50PDT"
      }

      post :create, params: @mobile_post_params.merge(consumption_event_params)

      expect(response.status).to be(401)
      expect(ConsumptionEvent.all.count).to eq(0)
    end

    it "uses the url_redirect's purchase id if one is not provided" do
      consumption_event_params = {
        event_type: "read",
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        platform: "android"
      }

      post :create, params: @mobile_post_params.merge(consumption_event_params)

      expect(response.parsed_body["success"]).to be(true)
      event = ConsumptionEvent.last
      expect(event.purchase_id).to be(@purchase.id)
    end

    it "successfully creates a consumption event with a url_redirect that does not have a purchase" do
      consumption_event_params = {
        event_type: "read",
        product_file_id: @product_file.external_id,
        url_redirect_id: @purchaseless_url_redirect.external_id,
        platform: "android"
      }

      post :create, params: @mobile_post_params.merge(consumption_event_params)

      expect(response.parsed_body["success"]).to be(true)
      event = ConsumptionEvent.last
      expect(event.purchase_id).to be(nil)
    end

    it "creates a consumption event with consumed_at set to the current_time now if one is not provided" do
      consumption_event_params = {
        event_type: "read",
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android"
      }
      travel_to Time.current

      post :create, params: @mobile_post_params.merge(consumption_event_params)

      expect(response.parsed_body["success"]).to be(true)
      event = ConsumptionEvent.last
      expect(event.consumed_at).to eq(Time.current.to_json) # to_json so it only has second precision
    end

    it "returns failed response if event_type is invalid" do
      consumption_event_params = {
        event_type: "location_watch",
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android"
      }

      post :create, params: @mobile_post_params.merge(consumption_event_params)

      expect(response.parsed_body["success"]).to be(false)
    end
  end
end
