# frozen_string_literal: true

require "spec_helper"

describe ProductsHelper, "url_for_product_page with offer codes" do
  include Rails.application.routes.url_helpers

  let(:creator) { create(:user, name: "Testy", username: "testy") }
  let(:product) { create(:product, unique_permalink: "test", name: "hello", user: creator) }

  describe "when offer_code is BLACKFRIDAY2025" do
    context "when on user's domain" do
      let(:request) { instance_double(ActionDispatch::Request, host: "testy.test.gumroad.com", host_with_port: "testy.test.gumroad.com:1234", protocol: "http") }

      before do
        allow_any_instance_of(ProductsHelper).to receive(:user_by_domain).with("testy.test.gumroad.com").and_return(creator)
      end

      it "adds code parameter to URL" do
        url = url_for_product_page(product, request:, offer_code: "BLACKFRIDAY2025")

        expect(url).to include("code=BLACKFRIDAY2025")
      end

      it "includes other parameters along with code" do
        url = url_for_product_page(
          product,
          request:,
          offer_code: "BLACKFRIDAY2025",
          recommended_by: "discover",
          query: "search term"
        )

        expect(url).to include("code=BLACKFRIDAY2025")
        expect(url).to include("recommended_by=discover")
        expect(url).to include("query=search+term")
      end
    end

    context "when not on user's domain" do
      let(:request) { instance_double(ActionDispatch::Request, host: "test.gumroad.com", host_with_port: "test.gumroad.com:1234", protocol: "http") }

      it "adds code parameter to URL" do
        url = url_for_product_page(product, request:, offer_code: "BLACKFRIDAY2025")

        expect(url).to include("code=BLACKFRIDAY2025")
      end

      it "includes other parameters except query" do
        url = url_for_product_page(
          product,
          request:,
          offer_code: "BLACKFRIDAY2025",
          recommended_by: "discover",
          query: "search term"
        )

        expect(url).to include("code=BLACKFRIDAY2025")
        expect(url).to include("recommended_by=discover")
        expect(url).not_to include("query=")
      end
    end
  end

  describe "when offer_code is nil" do
    let(:request) { instance_double(ActionDispatch::Request, host: "test.gumroad.com", host_with_port: "test.gumroad.com:1234", protocol: "http") }

    it "does not add code parameter to URL" do
      url = url_for_product_page(product, request:, offer_code: nil)

      expect(url).not_to include("code=")
    end
  end

  describe "when offer_code is empty string" do
    let(:request) { instance_double(ActionDispatch::Request, host: "test.gumroad.com", host_with_port: "test.gumroad.com:1234", protocol: "http") }

    it "does not add code parameter to URL" do
      url = url_for_product_page(product, request:, offer_code: "")

      expect(url).not_to include("code=")
    end
  end
end
