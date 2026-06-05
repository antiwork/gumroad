# frozen_string_literal: true

require "spec_helper"

describe "profile settings product routes" do
  def route_for(host)
    Rails.application.routes.recognize_path("http://#{host}/settings/profile/products/product-id", method: :get)
  end

  it "routes the product props endpoint on the app domain" do
    expect(route_for(DOMAIN)).to include(
      controller: "settings/profile/products",
      action: "show",
      id: "product-id"
    )
  end

  it "routes the product props endpoint on user custom domains" do
    create(:custom_domain, domain: "example.com", user: create(:user))

    expect(route_for("example.com")).to include(
      controller: "settings/profile/products",
      action: "show",
      id: "product-id"
    )
  end
end
