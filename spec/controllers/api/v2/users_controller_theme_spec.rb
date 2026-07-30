# frozen_string_literal: true

require "spec_helper"

# GET /v2/user/theme — the seller's store theme (background colour, highlight colour, font).
# This exists because the theme was previously invisible to every API caller, so the store agent
# could not see a theme the seller was plainly looking at on their own pages, and told them their
# product pages could not be styled at all (gumroad-private#1463).
describe Api::V2::UsersController, "GET 'theme'" do
  let(:seller) { create(:user) }
  let(:app) { create(:oauth_application, owner: create(:user)) }

  it "returns 401 without a token" do
    get :theme

    expect(response.status).to eq(401)
  end

  context "with a valid token" do
    let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "view_profile") }

    it "returns the seller's stored theme" do
      seller.seller_profile.update!(background_color: "#f4ecdc", highlight_color: "#6b7a3a", font: "Domine")

      get :theme, params: { access_token: token.token }

      expect(response).to be_successful
      theme = response.parsed_body["theme"]
      expect(theme["background_color"]).to eq("#f4ecdc")
      expect(theme["highlight_color"]).to eq("#6b7a3a")
      expect(theme["font"]).to eq("Domine")
    end

    it "returns the defaults for a seller who has never had a theme applied" do
      get :theme, params: { access_token: token.token }

      theme = response.parsed_body["theme"]
      expect(theme["background_color"]).to eq("#ffffff")
      expect(theme["highlight_color"]).to eq("#ff90e8")
      expect(theme["font"]).to eq("ABC Favorit")
    end

    # The costly wrong belief is that the theme only styles the profile page. It styles product
    # pages too, so the response says so explicitly rather than leaving the caller to assume.
    it "names product pages among the surfaces the theme applies to" do
      get :theme, params: { access_token: token.token }

      expect(response.parsed_body["theme"]["applies_to"]).to include("product pages")
    end

    # Only the posts a seller sends to their audience carry the theme; Gumroad's own transactional
    # mail (receipts, and so on) does not, so the list must not say a bare "emails".
    it "does not claim the theme covers Gumroad's own transactional email" do
      get :theme, params: { access_token: token.token }

      expect(response.parsed_body["theme"]["applies_to"]).not_to include("emails")
      expect(response.parsed_body["theme"]["applies_to"]).to include("the emails a seller sends to their audience")
    end

    # Checkout follows the theme only when every product being bought belongs to this seller, so an
    # unqualified "the checkout page" would overclaim for mixed carts — the qualifier is the point.
    it "names checkout among the surfaces, qualified to single-seller carts" do
      get :theme, params: { access_token: token.token }

      applies_to = response.parsed_body["theme"]["applies_to"]
      expect(applies_to).to include("the checkout page, but only when every product being bought is this seller's")
      expect(applies_to).not_to include("the checkout page")
    end

    it "says the seller cannot change the theme themselves and points at support" do
      get :theme, params: { access_token: token.token }

      theme = response.parsed_body["theme"]
      expect(theme["editable_by_seller"]).to be(false)
      expect(theme["how_to_change"]).to include("support")
    end
  end
end
