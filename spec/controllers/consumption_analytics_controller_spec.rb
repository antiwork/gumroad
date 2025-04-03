# frozen_string_literal: true

require "spec_helper"

describe ConsumptionAnalyticsController do
  describe "POST create" do
    before do
      @purchased_link = create(:product)
      @product_file = create(:product_file, link: @purchased_link)
      @purchase = create(:purchase, link: @purchased_link, purchase_state: :successful)
      @url_redirect = create(:url_redirect, purchase: @purchase)
      @purchaseless_url_redirect = create(:url_redirect, purchase: nil)
    end

    it "successfully creates consumption event" do
      params = {
        event_type: "read",
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android",
        consumed_at: "2015-09-09T17:26:50PDT"
      }

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(true)
      event = ConsumptionEvent.last
      expect(event.event_type).to eq(params[:event_type])
      expect(event.product_file_id).to be(@product_file.id)
      expect(event.url_redirect_id).to be(@url_redirect.id)
      expect(event.purchase_id).to be(@purchase.id)
      expect(event.link_id).to be(@purchased_link.id)
      expect(event.platform).to eq(params[:platform])
      expect(event.consumed_at).to eq(params[:consumed_at])
    end

    it "uses the url_redirect's purchase id if one is not provided" do
      params = {
        event_type: "read",
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        platform: "android"
      }

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(true)
      event = ConsumptionEvent.last
      expect(event.purchase_id).to be(@purchase.id)
    end

    it "successfully creates a consumption event with a url_redirect that does not have a purchase" do
      params = {
        event_type: "read",
        product_file_id: @product_file.external_id,
        url_redirect_id: @purchaseless_url_redirect.external_id,
        platform: "android"
      }

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(true)
      event = ConsumptionEvent.last
      expect(event.purchase_id).to be(nil)
    end

    it "creates a consumption event with consumed_at set to the current_time now if one is not provided" do
      params = {
        event_type: "read",
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "android"
      }
      travel_to Time.current

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(true)
      event = ConsumptionEvent.last
      expect(event.consumed_at).to eq(Time.current.to_json) # to_json so it only has second precision
    end

    it "returns failed response if event_type is invalid" do
      params = {
        event_type: "location_watch",
        product_file_id: @product_file.external_id,
        url_redirect_id: @url_redirect.external_id,
        purchase_id: @purchase.external_id,
        platform: "web"
      }

      post(:create, params:)

      expect(response.parsed_body["success"]).to be(false)
    end
  end
end
