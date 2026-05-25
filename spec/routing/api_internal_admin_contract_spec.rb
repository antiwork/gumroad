# frozen_string_literal: true

require "spec_helper"

describe "internal admin API routing" do
  def route_for(path, method)
    Rails.application.routes.recognize_path("https://#{API_DOMAIN}#{path}", method:)
  end

  # Contract for gumroad-cli: these are read-only GET routes the CLI depends on.
  # "Safe" here means no server-side state mutation (unlike write/refund/watch endpoints below).
  it "routes the safe read endpoints that gumroad-cli consumes" do
    expect(route_for("/internal/admin/purchases/123", :get)).to include(controller: "api/internal/admin/purchases", action: "show", id: "123")
    expect(route_for("/internal/admin/purchases/search", :get)).to include(controller: "api/internal/admin/purchases", action: "search")
    expect(route_for("/internal/admin/licenses/lookup", :get)).to include(controller: "api/internal/admin/licenses", action: "lookup")
    expect(route_for("/internal/admin/users/info", :get)).to include(controller: "api/internal/admin/users", action: "info")
    expect(route_for("/internal/admin/users/affiliates", :get)).to include(controller: "api/internal/admin/users", action: "affiliates")
    expect(route_for("/internal/admin/users/comments", :get)).to include(controller: "api/internal/admin/users", action: "comments")
    expect(route_for("/internal/admin/users/compliance_info", :get)).to include(controller: "api/internal/admin/users", action: "compliance_info")
    expect(route_for("/internal/admin/users/purchases", :get)).to include(controller: "api/internal/admin/users", action: "purchases")
    expect(route_for("/internal/admin/users/radar_stats", :get)).to include(controller: "api/internal/admin/users", action: "radar_stats")
    expect(route_for("/internal/admin/users/related", :get)).to include(controller: "api/internal/admin/users", action: "related")
    expect(route_for("/internal/admin/users/suspension", :get)).to include(controller: "api/internal/admin/users", action: "suspension")
    expect(route_for("/internal/admin/payouts", :get)).to include(controller: "api/internal/admin/payouts", action: "index")
  end

  it "routes the precise refund endpoint" do
    expect(route_for("/internal/admin/purchases/123/refund", :post)).to include(controller: "api/internal/admin/purchases", action: "refund", id: "123")
  end

  it "routes the user watchlist write endpoints" do
    expect(route_for("/internal/admin/users/watch", :post)).to include(controller: "api/internal/admin/users", action: "watch")
    expect(route_for("/internal/admin/users/update_watch", :post)).to include(controller: "api/internal/admin/users", action: "update_watch")
    expect(route_for("/internal/admin/users/unwatch", :post)).to include(controller: "api/internal/admin/users", action: "unwatch")
  end

  it "routes the user suspension write endpoints" do
    expect(route_for("/internal/admin/users/suspend_for_fraud", :post)).to include(
      controller: "api/internal/admin/users",
      action: "suspend_for_fraud"
    )
    expect(route_for("/internal/admin/users/suspend_for_tos_violation", :post)).to include(
      controller: "api/internal/admin/users",
      action: "suspend_for_tos_violation"
    )
  end

  it "routes the user policy-violation flag write endpoint" do
    expect(route_for("/internal/admin/users/flag_for_tos_violation", :post)).to include(
      controller: "api/internal/admin/users",
      action: "flag_for_tos_violation"
    )
  end

  it "routes the products endpoints" do
    expect(route_for("/internal/admin/products", :get)).to include(controller: "api/internal/admin/products", action: "index")
    expect(route_for("/internal/admin/products/abc123", :get)).to include(controller: "api/internal/admin/products", action: "show", id: "abc123")
  end
end
