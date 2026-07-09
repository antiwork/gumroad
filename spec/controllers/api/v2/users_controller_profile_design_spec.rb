# frozen_string_literal: true

require "spec_helper"

describe Api::V2::UsersController do
  before do
    @user = create(:user, name: "Jane Doe")
    @app = create(:oauth_application, owner: create(:user))
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_profile edit_profile")
  end

  describe "GET 'profile_design'" do
    it "returns the storefront design settings and the accepted font choices" do
      @user.seller_profile.update!(background_color: "#2e2e2e", highlight_color: "#ff90e8", font: "Inter")

      get :profile_design, params: { format: :json, access_token: @token.token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body["profile_design"]).to eq(
        "background_color" => "#2e2e2e",
        "highlight_color" => "#ff90e8",
        "font" => "Inter",
        "font_choices" => SellerProfile::FONT_CHOICES
      )
    end

    it "returns the defaults for a seller who never customized the design" do
      get :profile_design, params: { format: :json, access_token: @token.token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["profile_design"]["background_color"]).to eq("#ffffff")
      expect(body["profile_design"]["highlight_color"]).to eq("#ff90e8")
      expect(body["profile_design"]["font"]).to eq("ABC Favorit")
    end

    it "returns 401 without a token" do
      get :profile_design, params: { format: :json }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "PATCH 'update_profile_design'" do
    it "updates the background color on SellerProfile without touching custom HTML" do
      patch :update_profile_design, params: { format: :json, access_token: @token.token, background_color: "#ffe4ec" }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body["profile_design"]["background_color"]).to eq("#ffe4ec")
      expect(@user.reload.seller_profile.background_color).to eq("#ffe4ec")
      # The regression this endpoint prevents: a color change must never write the
      # custom-HTML page surface (gumroad-private#984).
      expect(@user.custom_html).to be_nil
    end

    it "updates highlight color and font together" do
      patch :update_profile_design, params: { format: :json, access_token: @token.token, highlight_color: "#111111", font: "Roboto Mono" }

      expect(response).to have_http_status(:ok)
      profile = @user.reload.seller_profile
      expect(profile.highlight_color).to eq("#111111")
      expect(profile.font).to eq("Roboto Mono")
    end

    it "invalidates the seller's product caches when the design changes" do
      expect_any_instance_of(User).to receive(:clear_products_cache)

      patch :update_profile_design, params: { format: :json, access_token: @token.token, background_color: "#123456" }

      expect(response).to have_http_status(:ok)
    end

    it "rejects a non-hex background color" do
      patch :update_profile_design, params: { format: :json, access_token: @token.token, background_color: "light pink" }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to match(/hexadecimal/i)
      expect(@user.reload.seller_profile.background_color).to eq("#ffffff")
    end

    it "rejects a font outside the accepted choices" do
      patch :update_profile_design, params: { format: :json, access_token: @token.token, font: "Comic Sans" }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(@user.reload.seller_profile.font).to eq("ABC Favorit")
    end

    it "rejects a request with none of the design params" do
      patch :update_profile_design, params: { format: :json, access_token: @token.token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to eq(false)
      expect(body["message"]).to match(/at least one/i)
    end

    it "requires a confirmed email" do
      @user.update!(confirmed_at: nil)

      patch :update_profile_design, params: { format: :json, access_token: @token.token, background_color: "#123456" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to eq(false)
    end

    it "rejects a token without the edit_profile scope" do
      read_only = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_profile")

      patch :update_profile_design, params: { format: :json, access_token: read_only.token, background_color: "#123456" }

      expect(response).to have_http_status(:forbidden)
    end
  end
end
