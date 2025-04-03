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
  end
end
