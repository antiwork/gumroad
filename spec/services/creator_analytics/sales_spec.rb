# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Sales do
  let(:user_timezone) { "UTC" }

  before do
    @user = create(:user, timezone: user_timezone)
    @products = create_list(:product, 2, user: @user)
    @service = described_class.new(
      user: @user,
      products: @products,
      dates: (Date.new(2021, 1, 1)..Date.new(2021, 1, 3)).to_a
    )
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 1), ip_country: "United States", ip_state: "CA", referrer: "https://google.com")
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 1, 1), ip_country: "Japan", referrer: "https://google.com")
    create(:purchase, link: @products[1], created_at: Time.utc(2021, 1, 1, 2))
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3), ip_country: "United States", ip_state: "NY", referrer: "https://t.co")
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3, 23, 30), is_gift_sender_purchase: true, ip_country: "United States", ip_state: "NY")
    preorder = create(:preorder)
    purchase = create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3), purchase_state: "preorder_concluded_successfully", ip_country: "France")
    purchase.update!(preorder:)
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3), preorder:, ip_country: "France", referrer: "https://t.co")
    purchase = create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3), is_gift_sender_purchase: true, ip_country: "France")
    purchase.refund_partial_purchase!(1, purchase.seller)
    purchase.refund_partial_purchase!(2, purchase.seller)
    create(:refund, purchase: create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3), stripe_refunded: true))
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3), chargeback_date: Time.current, chargeback_reversed: true)
    # invalid states
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3), is_gift_receiver_purchase: true, purchase_state: "gift_receiver_purchase_successful")
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3), purchase_state: "failed")
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 3), chargeback_date: Time.current)
    # outside of date range
    create(:purchase, link: @products[0], created_at: Time.utc(2021, 1, 4))
    index_model_records(Purchase)
  end

  describe "#by_product_and_date" do
    let(:expected_result) do
      {
        [@products[0].id, "2021-01-01"] => { count: 2, total: 200 },
        [@products[0].id, "2021-01-03"] => { count: 7, total: 497 },
        [@products[1].id, "2021-01-01"] => { count: 1, total: 100 },
      }
    end

    it "returns expected data" do
      expect(Purchase).to receive(:search).once.and_call_original
      result = @service.by_product_and_date
      expect(result).to eq(expected_result)
    end

    it "returns expected data when paginating" do
      stub_const("#{described_class}::ES_MAX_BUCKET_SIZE", 2)
      expect(Purchase).to receive(:search).exactly(2).times.and_call_original
      result = @service.by_product_and_date
      expect(result).to eq(expected_result)
    end

    context "when user time zone is Pacific Time" do
      let(:user_timezone) { "Pacific Time (US & Canada)" }

      it "returns expected data" do
        result = @service.by_product_and_date
        expected_result = {
          [@products[0].id, "2021-01-02"] => { count: 6, total: 397 },
          [@products[0].id, "2021-01-03"] => { count: 2, total: 200 },
        }
        expect(result).to eq(expected_result)
      end
    end

    context "when user time zone is Central European Time" do
      let(:user_timezone) { "Paris" }

      it "returns expected data" do
        result = @service.by_product_and_date
        expected_result = {
          [@products[0].id, "2021-01-01"] => { count: 2, total: 200 },
          [@products[0].id, "2021-01-03"] => { count: 3, total: 297 },
          [@products[0].id, "2021-01-03"] => { count: 6, total: 397 },
          [@products[1].id, "2021-01-01"] => { count: 1, total: 100 },
        }
        expect(result).to eq(expected_result)
      end
    end
  end

  describe "#by_product_and_country_and_state" do
    let(:expected_result) do
      {
        [@products[0].id, "France", nil] => { count: 2, total: 197 },
        [@products[0].id, "Japan", nil] => { count: 1, total: 100 },
        [@products[0].id, "United States", "CA"] => { count: 1, total: 100 },
        [@products[0].id, "United States", "NY"] => { count: 2, total: 200 },
        [@products[0].id, nil, nil] => { count: 3, total: 100 },
        [@products[1].id, nil, nil] => { count: 1, total: 100 },
      }
    end

    it "returns expected data with one query" do
      expect(Purchase).to receive(:search).once.and_call_original
      result = @service.by_product_and_country_and_state
      expect(result).to eq(expected_result)
    end

    it "returns expected data when paginating" do
      stub_const("#{described_class}::ES_MAX_BUCKET_SIZE", 2)
      expect(Purchase).to receive(:search).exactly(4).times.and_call_original
      result = @service.by_product_and_country_and_state
      expect(result).to eq(expected_result)
    end
  end

  describe "#by_product_and_referrer_and_date" do
    let(:expected_result) do
      {
        [@products[0].id, "direct", "2021-01-03"] => { count: 6, total: 397 },
        [@products[0].id, "google.com", "2021-01-01"] => { count: 2, total: 200 },
        [@products[0].id, "t.co", "2021-01-03"] => { count: 1, total: 100 },
        [@products[1].id, "direct", "2021-01-01"] => { count: 1, total: 100 },
      }
    end

    it "returns expected data with one query" do
      expect(Purchase).to receive(:search).once.and_call_original
      result = @service.by_product_and_referrer_and_date
      expect(result).to eq(expected_result)
    end

    it "returns expected data when paginating" do
      stub_const("#{described_class}::ES_MAX_BUCKET_SIZE", 2)
      expect(Purchase).to receive(:search).exactly(3).times.and_call_original
      result = @service.by_product_and_referrer_and_date
      expect(result).to eq(expected_result)
    end

    context "when user time zone is Pacific Time" do
      let(:user_timezone) { "Pacific Time (US & Canada)" }

      it "returns expected data" do
        result = @service.by_product_and_referrer_and_date
        expected_result = {
          [@products[0].id, "direct", "2021-01-02"] => { count: 5, total: 297 },
          [@products[0].id, "direct", "2021-01-03"] => { count: 2, total: 200 },
          [@products[0].id, "t.co", "2021-01-02"] => { count: 1, total: 100 },
        }
        expect(result).to eq(expected_result)
      end
    end

    context "when user time zone is Central European Time" do
      let(:user_timezone) { "Paris" }

      it "returns expected data" do
        result = @service.by_product_and_referrer_and_date
        expected_result = {
          [@products[0].id, "direct", "2021-01-03"] => { count: 5, total: 297 },
          [@products[0].id, "google.com", "2021-01-01"] => { count: 2, total: 200 },
          [@products[0].id, "t.co", "2021-01-03"] => { count: 1, total: 100 },
          [@products[1].id, "direct", "2021-01-01"] => { count: 1, total: 100 },
        }
        expect(result).to eq(expected_result)
      end
    end
  end

  describe "search option flags and query shape" do
    it "passes exclude_giftees: false and exclude_bundle_product_purchases: false to PurchaseSearchService" do
      expect(PurchaseSearchService).to receive(:new)
                                         .with(hash_including(
                                                 exclude_refunded: false,
                                                 exclude_unreversed_chargedback: false,
                                                 exclude_giftees: false,
                                                 exclude_bundle_product_purchases: false
                                               ))
                                         .and_call_original

      # instantiate a fresh service to trigger the expectation
      described_class.new(
        user: @user,
        products: @products,
        dates: (Date.new(2021, 1, 1)..Date.new(2021, 1, 3)).to_a
      )
    end

    it "builds a query that does NOT filter out giftees or bundle sub-purchases" do
      query = @service.instance_variable_get(:@query) # set during before block's initialization
      json = query.to_json
      expect(json).not_to include("is_gift_receiver_purchase") # would appear in must_not when excluding giftees
      expect(json).not_to include("is_bundle_product_purchase") # would appear in must_not when excluding sub-purchases
    end
  end
end
