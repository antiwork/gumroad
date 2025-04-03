# frozen_string_literal: true

require "spec_helper"
require "shared_examples/affiliate_cookie_concern"

describe AffiliateRedirectController do
  let(:creator) { create(:user) }
  let(:product) { create(:product, user: creator) }
  let(:product_2) { create(:product, user: creator) }
  let(:affiliate_user) { create(:affiliate_user) }
  let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller: creator) }
  let!(:product_affiliate) { create(:product_affiliate, product:, affiliate: direct_affiliate, affiliate_basis_points: 10_00) }

  before do
    sign_in(creator)
  end

  describe "set_cookie_and_redirect" do
    it "does not append anything to the redirect url if there were no url params" do
      get :set_cookie_and_redirect, params: { affiliate_id: direct_affiliate.external_id_numeric }
      expect(response).to be_redirect
      expect(response.location).not_to include("?")
      expect(response.location).not_to include("affiliate_id=")
    end

    context "when a custom destination URL is not set" do
      it "does not append anything to the redirect URL if there are no URL params" do
        get :set_cookie_and_redirect, params: { affiliate_id: direct_affiliate.external_id_numeric }

        expect(response).to be_redirect
        expect(response.location).not_to include("?")
        expect(response.location).not_to include("affiliate_id=")
      end

      it "preserves query parameters from the original request and appends them to the redirect URL but does not implicitly add the 'affiliate_id' query parameter" do
        get :set_cookie_and_redirect, params: { affiliate_id: direct_affiliate.external_id_numeric, amir: "cool", you: "also_cool" }

        expect(response).to be_redirect
        expect(response.location).not_to include("affiliate_id=#{direct_affiliate.external_id_numeric}")
        expect(response.location).to end_with("?amir=cool&you=also_cool")
      end

      it "redirects to the product URL" do
        get :set_cookie_and_redirect, params: { affiliate_id: direct_affiliate.external_id_numeric }

        expect(response).to redirect_to(product.long_url)
      end
    end

    context "when a custom destination URL is set" do
      it "implicitly adds 'affiliate_id' query parameter to the final destination URL during redirect" do
        direct_affiliate.update!(destination_url: "https://gumroad.com/l/abc", apply_to_all_products: true)

        get :set_cookie_and_redirect, params: { affiliate_id: direct_affiliate.external_id_numeric }

        expect(response).to be_redirect
        expect(response.location).to eq("https://gumroad.com/l/abc?affiliate_id=#{direct_affiliate.external_id_numeric}")
      end

      it "adds the 'affiliate_id' query parameter along with the other URL params to the redirect URL when the destination URL already contains URL params" do
        direct_affiliate.update!(destination_url: "https://gumroad.com/l/abc?from=affiliate", apply_to_all_products: true)

        get :set_cookie_and_redirect, params: { affiliate_id: direct_affiliate.external_id_numeric, amir: "cool", you: "also_cool" }

        expect(response).to be_redirect
        expect(response.location).to eq("https://gumroad.com/l/abc?affiliate_id=#{direct_affiliate.external_id_numeric}&amir=cool&from=affiliate&you=also_cool")
      end

      it "redirects to the custom URL" do
        direct_affiliate.update!(destination_url: "https://gumroad.com/l/abc", apply_to_all_products: true)

        get :set_cookie_and_redirect, params: { affiliate_id: direct_affiliate.external_id_numeric }

        expect(response).to redirect_to("https://gumroad.com/l/abc?affiliate_id=#{direct_affiliate.external_id_numeric}")
      end
    end

    it_behaves_like "AffiliateCookie concern" do
      subject(:make_request) { get :set_cookie_and_redirect, params: { affiliate_id: direct_affiliate.external_id_numeric } }
    end

    context "when affiliate has no destination URL set and has multiple products" do
      let(:creator) { create(:named_user) }
      let(:direct_affiliate) { create(:direct_affiliate, seller: creator, products: [create(:product), create(:product)]) }

      it "redirects to the creator's profile page" do
        get :set_cookie_and_redirect, params: { affiliate_id: direct_affiliate.external_id_numeric }

        expect(response).to redirect_to creator.subdomain_with_protocol
      end
    end
  end
end
