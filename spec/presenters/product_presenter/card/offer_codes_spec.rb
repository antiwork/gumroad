# frozen_string_literal: true

require "spec_helper"

describe ProductPresenter::Card, "with offer codes" do
  include Rails.application.routes.url_helpers

  let(:request) { instance_double(ActionDispatch::Request, host: "test.gumroad.com", host_with_port: "test.gumroad.com:1234", protocol: "http") }
  let(:creator) { create(:user, name: "Testy", username: "testy") }
  let(:product) { create(:product, unique_permalink: "test", name: "hello", user: creator) }
  let(:presenter) { described_class.new(product:) }

  describe "#for_web with offer_code parameter" do
    it "passes offer_code to url_for_product_page" do
      data = presenter.for_web(request:, offer_code: "BLACKFRIDAY2025")

      expect(data[:url]).to include("code=BLACKFRIDAY2025")
    end

    it "does not include code when offer_code is not BLACKFRIDAY2025" do
      data = presenter.for_web(request:, offer_code: "SUMMER2025")

      expect(data[:url]).not_to include("code=")
    end

    it "includes other URL parameters along with code" do
      data = presenter.for_web(
        request:,
        offer_code: "BLACKFRIDAY2025",
        recommended_by: "discover",
        query: "search term"
      )

      expect(data[:url]).to include("code=BLACKFRIDAY2025")
      expect(data[:url]).to include("recommended_by=discover")
      expect(data[:url]).to include("query=search+term")
    end

    it "works without offer_code parameter" do
      data = presenter.for_web(request:)

      expect(data[:url]).not_to include("code=")
      expect(data[:url]).to be_present
    end
  end
end
