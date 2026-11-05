# frozen_string_literal: true

require "spec_helper"

describe "Third-party analytics opt-out on checkout and receipt pages", type: :request do
  before { allow(Rails.env).to receive(:production?).and_return(true) }

  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  def meta_enabled(property)
    response.body[/#{property}" content="(\w+)"/, 1] || response.body[/content="(\w+)"[^>]*#{property}/, 1]
  end

  describe "GET /checkout" do
    it "keeps analytics on when no seller opted out" do
      get checkout_url(host: DOMAIN, protocol: PROTOCOL, product: product.unique_permalink)
      expect(meta_enabled("gr:google_analytics:enabled")).to eq("true")
    end

    it "loads no analytics for an opted-out seller's product arriving via the checkout link" do
      seller.update!(disable_third_party_analytics: true)
      get checkout_url(host: DOMAIN, protocol: PROTOCOL, product: product.unique_permalink)
      %w[gr:google_analytics:enabled gr:fb_pixel:enabled gr:tiktok_pixel:enabled].each do |property|
        expect(meta_enabled(property)).to eq("false")
      end
    end
  end

  describe "receipt pages" do
    let(:purchase) { create(:purchase, link: product) }

    it "keeps analytics on the receipt email-confirmation page when the seller did not opt out" do
      get confirm_receipt_email_purchase_url(purchase.external_id, host: DOMAIN, protocol: PROTOCOL)
      expect(meta_enabled("gr:google_analytics:enabled")).to eq("true")
    end

    it "loads no analytics on the receipt email-confirmation page for an opted-out seller" do
      seller.update!(disable_third_party_analytics: true)
      get confirm_receipt_email_purchase_url(purchase.external_id, host: DOMAIN, protocol: PROTOCOL)
      expect(meta_enabled("gr:google_analytics:enabled")).to eq("false")
    end

    it "serves the receipt itself without any analytics script" do
      get receipt_purchase_url(purchase.external_id, host: DOMAIN, protocol: PROTOCOL, email: purchase.email)
      expect(response).to be_successful
      expect(response.body).not_to include("googletagmanager", "gr:google_analytics")
    end
  end
end
