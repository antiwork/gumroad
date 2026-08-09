# frozen_string_literal: true

require "spec_helper"

describe FaviconsController do
  render_views false

  describe "GET show" do
    context "on a seller's subdomain" do
      it "redirects to the seller's own avatar" do
        user = create(:named_user)
        get :show, params: {}, env: { "HTTP_HOST" => "#{user.username}.gumroad.com" }
        expect(response).to redirect_to(user.avatar_url)
      end
    end

    context "on a seller's custom domain" do
      it "redirects to the seller's own avatar" do
        user = create(:named_user)
        create(:custom_domain, user:, domain: "www.example-seller.com")
        get :show, params: {}, env: { "HTTP_HOST" => "www.example-seller.com" }
        expect(response).to redirect_to(user.avatar_url)
      end
    end

    context "on the canonical gumroad.com host" do
      it "serves the generic static icon rather than redirecting" do
        get :show, params: {}, env: { "HTTP_HOST" => "gumroad.com" }
        expect(response).to have_http_status(:ok)
        expect(response.content_type).to eq("image/x-icon")
      end
    end

    context "when no seller resolves for the host" do
      it "falls back to the generic static icon" do
        get :show, params: {}, env: { "HTTP_HOST" => "no-such-seller.gumroad.com" }
        expect(response).to have_http_status(:ok)
        expect(response.content_type).to eq("image/x-icon")
      end
    end
  end
end
