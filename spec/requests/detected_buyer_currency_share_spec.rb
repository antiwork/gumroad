# frozen_string_literal: true

require "spec_helper"

# The footer currency selector needs the IP-detected currency, and computing it costs a GeoIP
# lookup. Sharing it from every Inertia response put that lookup on every dashboard render too,
# so controllers opt in with `shares_buyer_currency`. These specs pin both halves of that gate.
describe "detected_buyer_currency Inertia share", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user, username: "currencyseller") }

  before do
    allow(GeoIp).to receive(:lookup).and_return(
      GeoIp::Result.new(
        country_name: "France", country_code: "FR", region_name: "IDF",
        city_name: "Paris", postal_code: "75001", latitude: nil, longitude: nil
      )
    )
  end

  def inertia_props(url)
    get url, headers: { "X-Inertia" => "true" }
    expect(response).to be_successful
    JSON.parse(response.body).fetch("props")
  end

  it "shares the detected currency on a buyer-facing page that mounts the selector" do
    expect(inertia_props("#{seller.subdomain_with_protocol}/")["detected_buyer_currency"]).to eq("eur")
  end

  it "omits the detected currency from a dashboard page that has no selector" do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
    sign_in seller

    expect(inertia_props(settings_main_path)).not_to have_key("detected_buyer_currency")
  end

  # LinksController serves both the buyer's product page and the seller's product list, so the
  # opt-in is per action rather than per controller.
  it "omits the detected currency from a seller action on a controller that opts in elsewhere" do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
    sign_in seller

    expect(inertia_props(products_path)).not_to have_key("detected_buyer_currency")
  end

  it "omits the detected currency when the lookup finds no supported currency" do
    allow(GeoIp).to receive(:lookup).and_return(nil)

    expect(inertia_props("#{seller.subdomain_with_protocol}/")["detected_buyer_currency"]).to be_nil
  end
end
