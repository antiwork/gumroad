# frozen_string_literal: true

require "spec_helper"

describe "internal admin API routing" do
  def route_for(path, method)
    Rails.application.routes.recognize_path("https://#{API_DOMAIN}#{path}", method:)
  end

  it "routes the safe read endpoints that gumroad-cli consumes" do
    expect(route_for("/internal/admin/purchases/123", :get)).to include(controller: "api/internal/admin/purchases", action: "show", id: "123")
    expect(route_for("/internal/admin/purchases/search", :post)).to include(controller: "api/internal/admin/purchases", action: "search")
    expect(route_for("/internal/admin/licenses/lookup", :post)).to include(controller: "api/internal/admin/licenses", action: "lookup")
    expect(route_for("/internal/admin/users/suspension", :post)).to include(controller: "api/internal/admin/users", action: "suspension")
    expect(route_for("/internal/admin/payouts/list", :post)).to include(controller: "api/internal/admin/payouts", action: "list")
  end

  it "routes the precise refund endpoint" do
    expect(route_for("/internal/admin/purchases/123/refund", :post)).to include(controller: "api/internal/admin/purchases", action: "refund", id: "123")
  end
end
