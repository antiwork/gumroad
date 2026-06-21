# frozen_string_literal: true

require "spec_helper"

describe "profile settings product routes" do
  it "routes the product props endpoint to settings/profile/products#show" do
    expect(
      Rails.application.routes.recognize_path("http://#{DOMAIN}/profile/products/product-id", method: :get)
    ).to include(
      controller: "settings/profile/products",
      action: "show",
      id: "product-id"
    )
  end
end
