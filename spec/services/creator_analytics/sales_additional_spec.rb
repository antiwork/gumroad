# frozen_string_literal: true

require "rails_helper"

RSpec.describe CreatorAnalytics::Sales do
  describe "Additional tests for gifted bundle purchases in analytics" do
    let(:seller) { create(:user) }
    let(:buyer) { create(:user) }
    let(:bundle) { create(:bundle, user: seller, price_cents: 3000) }
    let(:product1) { create(:product, user: seller, price_cents: 1000) }
    let(:product2) { create(:product, user: seller, price_cents: 1500) }
    let(:dates) { [Date.today] }

    before do
      bundle.links << [product1, product2]
      allow(PurchaseSearchService).to receive(:new).and_call_original
    end

    context "when including gifted bundle purchases in sales analytics" do
      let!(:regular_purchase) do
        create(:purchase, link: bundle, price_cents: 3000, created_at: Date.today)
      end

      let!(:gift_purchase) do
        purchase = create(:purchase, 
                         link: bundle, 
                         price_cents: 3000, 
                         is_gift_sender_purchase: true,
                         created_at: Date.today)
        create(:gift_given, purchase: purchase)
        purchase
      end

      let!(:giftee_purchase) do
        create(:purchase,
               link: bundle,
               price_cents: 0,
               is_gift_receiver_purchase: true,
               created_at: Date.today)
      end

      it "includes giftee purchases when exclude_giftees is false" do
        service = described_class.new(user: seller, products: [bundle], dates: dates)
        expect(described_class::SEARCH_OPTIONS[:exclude_giftees]).to eq(false)
      end

      it "includes bundle product purchases when exclude_bundle_product_purchases is false" do
        service = described_class.new(user: seller, products: [bundle], dates: dates)
        expect(described_class::SEARCH_OPTIONS[:exclude_bundle_product_purchases]).to eq(false)
      end
    end

    context "when analyzing sales by product and date for gifted bundles" do
      let(:service) { described_class.new(user: seller, products: [bundle, product1], dates: dates) }

      before do
        # Mock Elasticsearch response
        allow_any_instance_of(described_class).to receive(:paginate).and_return([
          {
            "key" => { "product_id" => bundle.id, "date" => Date.today.to_s },
            "doc_count" => 5,
            "total" => { "value" => 15000 }
          },
          {
            "key" => { "product_id" => product1.id, "date" => Date.today.to_s },
            "doc_count" => 3,
            "total" => { "value" => 3000 }
          }
        ])
      end

      it "correctly aggregates gifted bundle sales by product and date" do
        results = service.by_product_and_date
        
        expect(results[[bundle.id, Date.today.to_s]]).to eq(
          count: 5,
          total: 15000
        )
        
        expect(results[[product1.id, Date.today.to_s]]).to eq(
          count: 3,
          total: 3000
        )
      end
    end

    context "when analyzing sales by product, country, and state for gifted bundles" do
      let(:service) { described_class.new(user: seller, products: [bundle], dates: dates) }

      before do
        allow_any_instance_of(described_class).to receive(:paginate).and_return([
          {
            "key" => { 
              "product_id" => bundle.id, 
              "country" => "US", 
              "state" => "CA" 
            },
            "doc_count" => 10,
            "total" => { "value" => 30000 }
          },
          {
            "key" => { 
              "product_id" => bundle.id, 
              "country" => "US", 
              "state" => "NY" 
            },
            "doc_count" => 8,
            "total" => { "value" => 24000 }
          }
        ])
      end

      it "correctly aggregates gifted bundle sales by location" do
        results = service.by_product_and_country_and_state
        
        expect(results[[bundle.id, "US", "CA"]]).to eq(
          count: 10,
          total: 30000
        )
        
        expect(results[[bundle.id, "US", "NY"]]).to eq(
          count: 8,
          total: 24000
        )
      end
    end

    context "when handling edge cases in analytics queries" do
      let(:service) { described_class.new(user: seller, products: [], dates: dates) }

      it "handles empty product list gracefully" do
        expect { service.by_product_and_date }.not_to raise_error
      end

      it "handles nil dates gracefully" do
        service_with_nil = described_class.new(user: seller, products: [bundle], dates: [nil])
        expect { service_with_nil.by_product_and_date }.not_to raise_error
      end
    end
  end
end