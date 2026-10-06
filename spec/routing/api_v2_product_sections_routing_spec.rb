# frozen_string_literal: true

require "spec_helper"

describe "product sections API routing" do
  def route_for(host, path, method)
    Rails.application.routes.recognize_path("https://#{host}#{path}", method:)
  end

  it "routes the sections write on both API mounts" do
    [
      [API_DOMAIN, "/v2/products/product-id/sections"],
      [DOMAIN, "/api/v2/products/product-id/sections"],
    ].each do |host, path|
      expect(route_for(host, path, :put)).to include(
        controller: "api/v2/links",
        action: "update_sections",
        id: "product-id",
      )
    end
  end

  # The legacy `/links/:id/sections` path on the storefront mount resolves to the dashboard's
  # LinksController, not this API controller; there is no `/v2/links/:id/sections` route.
  it "does not route a sections read or PATCH" do
    # The API mount's catch-all answers an unrouted GET with the 404 page, so assert the controller
    # action is not what answered.
    expect(route_for(API_DOMAIN, "/v2/products/product-id/sections", :get))
      .not_to include(controller: "api/v2/links", action: "update_sections")
    expect { route_for(API_DOMAIN, "/v2/products/product-id/sections", :patch) }
      .to raise_error(ActionController::RoutingError)
  end
end
