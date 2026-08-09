# frozen_string_literal: true

require "spec_helper"

describe FaviconsController do
  describe "GET show" do
    context "on a seller's subdomain" do
      it "redirects to the seller's own avatar" do
        user = create(:named_user)
        @request.host = Subdomain.from_username(user.username)
        get :show
        expect(response).to redirect_to(user.avatar_url)
      end
    end

    context "on a seller's custom domain" do
      it "redirects to the seller's own avatar" do
        user = create(:named_user)
        create(:custom_domain, user:, domain: "www.example-seller.com")
        @request.host = "www.example-seller.com"
        get :show
        expect(response).to redirect_to(user.avatar_url)
      end
    end

    context "on the canonical gumroad host" do
      it "serves the generic static icon rather than redirecting" do
        @request.host = URI("#{PROTOCOL}://#{DOMAIN}").host
        get :show
        expect(response).to have_http_status(:ok)
        expect(response.content_type).to eq("image/x-icon")
      end
    end

    context "when no seller resolves for the host" do
      it "falls back to the generic static icon" do
        @request.host = Subdomain.from_username("no-such-seller")
        get :show
        expect(response).to have_http_status(:ok)
        expect(response.content_type).to eq("image/x-icon")
      end
    end
  end
end
