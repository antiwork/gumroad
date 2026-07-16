# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Web do
  before do
    @user = create(:user, timezone: "UTC")
    @products = create_list(:product, 2, user: @user)
    @service = described_class.new(
      user: @user,
      dates: (Date.new(2021, 1, 1) .. Date.new(2021, 1, 3)).to_a
    )

    add_page_view(@products[0], Time.utc(2021, 1, 1))
    add_page_view(@products[0], Time.utc(2021, 1, 3), country: "France")
    add_page_view(@products[0], Time.utc(2021, 1, 3), referrer_domain: "google.com", country: "France", state: "75")
    add_page_view(@products[0], Time.utc(2021, 1, 3), referrer_domain: "google.com", country: "United States", state: "NY")
    add_page_view(@products[1], Time.utc(2021, 1, 3), referrer_domain: "google.com", country: "United States", state: "NY")
    ProductPageView.__elasticsearch__.refresh_index!

    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 1))
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3), ip_country: "France")
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3), ip_country: "United States", ip_state: "NY", referrer: "https://google.com")
    create(:purchase, link: @products[1], created_at: Time.utc(2021, 1, 3), ip_country: "United States", ip_state: "NY", referrer: "https://google.com")
    index_model_records(Purchase)
  end

  describe "#by_date" do
    it "returns expected data" do
      expected_result = {
        dates_and_months: [
          { date: "Friday, January 1st", month: "January 2021", month_index: 0 },
          { date: "Saturday, January 2nd", month: "January 2021", month_index: 0 },
          { date: "Sunday, January 3rd", month: "January 2021", month_index: 0 }
        ],
        start_date: "Jan  1, 2021",
        end_date: "Jan  3, 2021",
        first_sale_date: "Jan  1, 2021",
        by_date: {
          views: { @products[0].unique_permalink => [1, 0, 3], @products[1].unique_permalink => [0, 0, 1] },
          sales: { @products[0].unique_permalink => [1, 0, 2], @products[1].unique_permalink => [0, 0, 1] },
          totals: { @products[0].unique_permalink => [100, 0, 200], @products[1].unique_permalink => [0, 0, 100] }
        }
      }

      expect(@service.by_date).to eq(expected_result)
    end
  end

  describe "hourly interval" do
    let(:hourly_service) do
      described_class.new(user: @user, dates: [Date.new(2021, 1, 1)], interval: "hour")
    end

    it "returns hourly buckets for #by_date" do
      result = hourly_service.by_date

      expect(result[:dates_and_months].size).to eq(24)
      expect(result[:dates_and_months].first).to eq(date: "Friday, January 1st, 12 AM", month: "January 2021", month_index: 0)
      expect(result[:dates_and_months].second).to eq(date: "Friday, January 1st, 1 AM", month: "January 2021", month_index: 0)
      expect(result[:by_date][:views][@products[0].unique_permalink]).to eq([1] + [0] * 23)
      expect(result[:by_date][:sales][@products[0].unique_permalink]).to eq([1] + [0] * 23)
      expect(result[:by_date][:totals][@products[0].unique_permalink]).to eq([100] + [0] * 23)
      expect(result[:by_date][:views][@products[1].unique_permalink]).to eq([0] * 24)
    end

    it "returns hourly buckets for #by_referral" do
      result = hourly_service.by_referral

      expect(result[:dates_and_months].size).to eq(24)
      expect(result[:by_referral][:views][@products[0].unique_permalink]["direct"]).to eq([1] + [0] * 23)
      expect(result[:by_referral][:sales][@products[0].unique_permalink]["direct"]).to eq([1] + [0] * 23)
      expect(result[:by_referral][:totals][@products[0].unique_permalink]["direct"]).to eq([100] + [0] * 23)
    end

    it "aligns hourly buckets with the seller's timezone" do
      user = create(:user, timezone: "Pacific Time (US & Canada)")
      product = create(:product, user: user)
      # 20:00 UTC on Jan 1 is noon Pacific time, so the sale must land at index 12.
      create(:purchase, link: product, created_at: Time.utc(2021, 1, 1, 20))
      index_model_records(Purchase)

      result = described_class.new(user:, dates: [Date.new(2021, 1, 1)], interval: "hour").by_date

      expect(result[:by_date][:sales][product.unique_permalink]).to eq([0] * 12 + [1] + [0] * 11)
      expect(result[:dates_and_months][12]).to eq(date: "Friday, January 1st, 12 PM", month: "January 2021", month_index: 0)
    end

    it "keeps the hour domain inside the requested range when DST starts at midnight" do
      # In Santiago, DST begins at midnight on Sep 6, 2026, so that local day has
      # no 00:00 and only 23 hours; the domain must not leak a Sep 7 bucket.
      user = create(:user, timezone: "Santiago")

      result = described_class.new(user:, dates: [Date.new(2026, 9, 6)], interval: "hour").by_date

      expect(result[:dates_and_months].size).to eq(23)
      expect(result[:dates_and_months].first[:date]).to eq("Sunday, September 6th, 1 AM")
      expect(result[:dates_and_months].last[:date]).to eq("Sunday, September 6th, 11 PM")
    end
  end

  describe "#by_state" do
    it "returns expected data" do
      expected_result = {
        by_state: {
          views: {
            @products[0].unique_permalink => {
              "United States" => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
              nil => 1,
              "France" => 2
            },
            @products[1].unique_permalink => {
              "United States" => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            }
          },
          sales: {
            @products[0].unique_permalink => {
              "United States" => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
              nil => 1,
              "France" => 1
            },
            @products[1].unique_permalink => {
              "United States" => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            }
          },
          totals: {
            @products[0].unique_permalink => {
              "United States" => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
              nil => 100,
              "France" => 100
            },
            @products[1].unique_permalink => {
              "United States" => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            }
          }
        }
      }

      expect(@service.by_state).to eq(expected_result)
    end
  end

  describe "#by_referral" do
    it "returns expected data" do
      expected_result = {
        dates_and_months: [
          { date: "Friday, January 1st", month: "January 2021", month_index: 0 },
          { date: "Saturday, January 2nd", month: "January 2021", month_index: 0 },
          { date: "Sunday, January 3rd", month: "January 2021", month_index: 0 }
        ],
        start_date: "Jan  1, 2021",
        end_date: "Jan  3, 2021",
        first_sale_date: "Jan  1, 2021",
        by_referral: {
          views: {
            @products[0].unique_permalink => {
              "Google" => [0, 0, 2],
              "direct" => [1, 0, 1]
            },
            @products[1].unique_permalink => {
              "Google" => [0, 0, 1]
            }
          },
          sales: {
            @products[0].unique_permalink => {
              "Google" => [0, 0, 1],
              "direct" => [1, 0, 1]
            },
            @products[1].unique_permalink => {
              "Google" => [0, 0, 1]
            }
          },
          totals: {
            @products[0].unique_permalink => {
              "Google" => [0, 0, 100],
              "direct" => [100, 0, 100]
            },
            @products[1].unique_permalink => {
              "Google" => [0, 0, 100]
            }
          }
        }
      }

      expect(@service.by_referral).to eq(expected_result)
    end

    it "keeps filters aligned with histogram buckets when midnight is skipped" do
      user = create(:user, timezone: "Tehran")
      product = create(:product, user: user)
      service = described_class.new(user: user, dates: [Date.new(2026, 3, 22)])

      Time.use_zone(user.timezone) do
        add_page_view(product, Time.zone.parse("2026-03-22 01:15:00").utc, referrer_domain: "google.com")
        add_page_view(product, Time.zone.parse("2026-03-23 00:15:00").utc, referrer_domain: "t.co")
        create(:free_purchase, link: product, created_at: Time.zone.parse("2026-03-22 01:15:00").utc, referrer: "https://google.com")
        create(:free_purchase, link: product, created_at: Time.zone.parse("2026-03-23 00:15:00").utc, referrer: "https://t.co")
      end
      ProductPageView.__elasticsearch__.refresh_index!
      index_model_records(Purchase)

      expect { service.by_referral }.not_to raise_error
      expect(service.by_referral).to include(
        by_referral: {
          views: { product.unique_permalink => { "Google" => [1] } },
          sales: { product.unique_permalink => { "Google" => [1] } },
          totals: { product.unique_permalink => { "Google" => [0] } }
        }
      )
    end
  end
end
