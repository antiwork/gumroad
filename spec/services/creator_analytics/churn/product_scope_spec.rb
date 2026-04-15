# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Churn::ProductScope do
  let(:seller) { create(:user, timezone: "UTC") }
  let(:service) { described_class.new(seller:) }

  def create_product_with_purchase(created_at: nil, **product_options)
    product = create(:product, user: seller, **product_options)
    create(:purchase, link: product, created_at:)
    product
  end

  def date_in_seller_timezone(time)
    time.in_time_zone(seller.timezone).to_date
  end

  describe "#subscription_products" do
    let!(:recurring_product) { create(:product, :is_subscription, user: seller) }
    let!(:tiered_product) { create(:membership_product, user: seller) }
    let!(:regular_product) { create(:product, user: seller) }

    before do
      create(:purchase, link: recurring_product)
      create(:purchase, link: tiered_product)
      create(:purchase, link: regular_product)
    end

    it "returns only recurring billing and tiered membership products" do
      products = service.subscription_products

      expect(products).to include(recurring_product)
      expect(products).to include(tiered_product)
      expect(products).not_to include(regular_product)
    end

    it "memoizes the result" do
      expect(seller).to receive(:products_for_creator_analytics).once.and_call_original

      service.subscription_products
      service.subscription_products
    end
  end

  describe "#product_map" do
    let!(:recurring_product) { create(:product, :is_subscription, user: seller, name: "Recurring Product") }
    let!(:tiered_product) { create(:membership_product, user: seller, name: "Tiered Product") }

    before do
      create(:purchase, link: recurring_product)
      create(:purchase, link: tiered_product)
    end

    it "returns a hash mapping product id to product info" do
      product_map = service.product_map

      expect(product_map).to be_a(Hash)
      expect(product_map[recurring_product.id]).to eq(
        id: recurring_product.id,
        external_id: recurring_product.external_id,
        permalink: recurring_product.unique_permalink,
        name: "Recurring Product"
      )
      expect(product_map[tiered_product.id]).to eq(
        id: tiered_product.id,
        external_id: tiered_product.external_id,
        permalink: tiered_product.unique_permalink,
        name: "Tiered Product"
      )
    end

    it "memoizes the result" do
      expect(service).to receive(:subscription_products).once.and_call_original

      service.product_map
      service.product_map
    end
  end

  describe "#earliest_analytics_date" do
    context "when seller has a first sale" do
      let(:first_sale_time) { Time.utc(2020, 1, 15, 10, 30) }

      before do
        create_product_with_purchase(created_at: first_sale_time)
      end

      it "returns the first sale date in seller's timezone" do
        expect(service.earliest_analytics_date).to eq(date_in_seller_timezone(first_sale_time))
      end
    end

    context "when seller has no sales" do
      let(:seller_created_at) { Time.utc(2020, 1, 1, 12, 0) }

      before do
        seller.update!(created_at: seller_created_at)
      end

      it "returns seller created_at date in seller's timezone" do
        expect(service.earliest_analytics_date).to eq(date_in_seller_timezone(seller_created_at))
      end
    end

    context "when seller timezone is Pacific Time" do
      let(:seller) { create(:user, timezone: "Pacific Time (US & Canada)") }
      let(:first_sale_time) { Time.utc(2020, 1, 15, 8, 0) }

      before do
        create_product_with_purchase(created_at: first_sale_time)
      end

      it "returns the date in Pacific Time" do
        expect(service.earliest_analytics_date).to eq(date_in_seller_timezone(first_sale_time))
      end
    end

    it "memoizes the result" do
      expect(service).to receive(:first_sale_date).once.and_call_original

      service.earliest_analytics_date
      service.earliest_analytics_date
    end
  end

  describe "#first_sale_date" do
    context "when seller has a first sale" do
      let(:first_sale_time) { Time.utc(2020, 1, 15, 10, 30) }

      before do
        create_product_with_purchase(created_at: first_sale_time)
      end

      it "returns the first sale date in seller's timezone" do
        expect(service.first_sale_date).to eq(date_in_seller_timezone(first_sale_time))
      end
    end

    context "when seller has no sales" do
      it "returns nil" do
        expect(service.first_sale_date).to be_nil
      end
    end

    context "when seller has multiple sales" do
      let(:earliest_sale_time) { Time.utc(2020, 1, 10, 10, 0) }
      let(:later_sale_time) { Time.utc(2020, 1, 20, 10, 0) }

      before do
        create_product_with_purchase(created_at: later_sale_time)
        create_product_with_purchase(created_at: earliest_sale_time)
      end

      it "returns the earliest sale date" do
        expect(service.first_sale_date).to eq(date_in_seller_timezone(earliest_sale_time))
      end
    end

    it "memoizes the result" do
      create_product_with_purchase

      expect(seller).to receive(:first_sale_created_at_for_analytics).once.and_call_original

      service.first_sale_date
      service.first_sale_date
    end
  end
end
