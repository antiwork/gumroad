# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::ProductPageViews do
  let(:user_timezone) { "UTC" }

  before do
    @user = create(:user, timezone: user_timezone)
    @products = create_list(:product, 2, user: @user)
    @service = described_class.new(
      user: @user,
      products: @products,
      dates: (Date.new(2021, 1, 1) .. Date.new(2021, 1, 3)).to_a
    )
  end

  describe "#by_product_and_date" do
    before do
      add_page_view(@products[0], Time.utc(2021, 1, 1))
      add_page_view(@products[0], Time.utc(2021, 1, 1, 1))
      add_page_view(@products[1], Time.utc(2021, 1, 1, 2))
      add_page_view(@products[0], Time.utc(2021, 1, 3, 23, 30))
      add_page_view(@products[0], Time.utc(2021, 1, 4))
      ProductPageView.__elasticsearch__.refresh_index!
    end

    it "returns expected data" do
      result = @service.by_product_and_date
      expected_result = {
        [@products[0].id, "2021-01-01"] => 2,
        [@products[0].id, "2021-01-03"] => 1,
        [@products[1].id, "2021-01-01"] => 1,
      }
      expect(result).to eq(expected_result)
    end

    context "when user time zone is Pacific Time" do
      let(:user_timezone) { "Pacific Time (US & Canada)" }

      it "returns expected data" do
        result = @service.by_product_and_date
        expected_result = {
          [@products[0].id, "2021-01-03"] => 2,
        }
        expect(result).to eq(expected_result)
      end
    end

    context "when user time zone is Central European Time" do
      let(:user_timezone) { "Paris" }

      it "returns expected data" do
        result = @service.by_product_and_date
        expected_result = {
          [@products[0].id, "2021-01-01"] => 2,
          [@products[1].id, "2021-01-01"] => 1,
        }
        expect(result).to eq(expected_result)
      end
    end
  end

  describe "#by_product_and_country_and_state" do
    before do
      add_page_view(@products[0], Time.utc(2021, 1, 1), country: "United States", state: "CA")
      add_page_view(@products[0], Time.utc(2021, 1, 1, 1), country: "Japan", state: nil)
      add_page_view(@products[1], Time.utc(2021, 1, 1, 2), country: "United States", state: "NY")
      add_page_view(@products[0], Time.utc(2021, 1, 3), country: "United States", state: "CA")
      add_page_view(@products[0], Time.utc(2021, 1, 4), country: "United States", state: "WA")
      ProductPageView.__elasticsearch__.refresh_index!
    end

    let(:expected_result) do
      {
        [@products[0].id, "United States", "CA"] => 2,
        [@products[0].id, "Japan", nil] => 1,
        [@products[1].id, "United States", "NY"] => 1
      }
    end

    it "returns expected data with one query" do
      expect(ProductPageView).to receive(:search).once.and_call_original
      result = @service.by_product_and_country_and_state
      expect(result).to eq(expected_result)
    end

    it "returns expected data when paginating" do
      stub_const("#{described_class}::ES_MAX_BUCKET_SIZE", 2)
      expect(ProductPageView).to receive(:search).exactly(2).times.and_call_original
      result = @service.by_product_and_country_and_state
      expect(result).to eq(expected_result)
    end
  end

  describe "#by_product_and_referrer_and_date" do
    before do
      add_page_view(@products[0], Time.utc(2021, 1, 1), referrer_domain: "google.com")
      add_page_view(@products[0], Time.utc(2021, 1, 1), referrer_domain: "direct")
      add_page_view(@products[1], Time.utc(2021, 1, 3), referrer_domain: "google.com")
      add_page_view(@products[0], Time.utc(2021, 1, 3), referrer_domain: "direct")
      add_page_view(@products[0], Time.utc(2021, 1, 3), referrer_domain: "direct")
      add_page_view(@products[0], Time.utc(2021, 1, 3, 23, 30), referrer_domain: "t.co")
      add_page_view(@products[0], Time.utc(2021, 1, 4), referrer_domain: "medium.com")
      ProductPageView.__elasticsearch__.refresh_index!
    end

    let(:expected_result) do
      {
        [@products[0].id, "google.com", "2021-01-01"] => 1,
        [@products[0].id, "direct", "2021-01-01"] => 1,
        [@products[1].id, "google.com", "2021-01-03"] => 1,
        [@products[0].id, "direct", "2021-01-03"] => 2,
        [@products[0].id, "t.co", "2021-01-03"] => 1,
      }
    end

    it "returns expected data with one query" do
      expect(ProductPageView).to receive(:search).once.and_call_original
      result = @service.by_product_and_referrer_and_date
      expect(result).to eq(expected_result)
    end

    it "returns expected data when paginating" do
      stub_const("#{described_class}::ES_MAX_BUCKET_SIZE", 4)
      expect(ProductPageView).to receive(:search).exactly(2).times.and_call_original
      result = @service.by_product_and_referrer_and_date
      expect(result).to eq(expected_result)
    end

    context "when user time zone is Pacific Time" do
      let(:user_timezone) { "Pacific Time (US & Canada)" }

      it "returns expected data" do
        result = @service.by_product_and_referrer_and_date
        expected_result = {
          [@products[0].id, "direct", "2021-01-02"] => 2,
          [@products[0].id, "medium.com", "2021-01-03"] => 1,
          [@products[0].id, "t.co", "2021-01-03"] => 1,
          [@products[1].id, "google.com", "2021-01-02"] => 1,
        }
        expect(result).to eq(expected_result)
      end
    end

    context "when user time zone is Central European Time" do
      let(:user_timezone) { "Paris" }

      it "returns expected data" do
        result = @service.by_product_and_referrer_and_date
        expected_result = {
          [@products[0].id, "google.com", "2021-01-01"] => 1,
          [@products[0].id, "direct", "2021-01-01"] => 1,
          [@products[1].id, "google.com", "2021-01-03"] => 1,
          [@products[0].id, "direct", "2021-01-03"] => 2,
        }
        expect(result).to eq(expected_result)
      end
    end
  end
end
