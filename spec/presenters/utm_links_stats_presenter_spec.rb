# frozen_string_literal: true

require "spec_helper"

describe UtmLinksStatsPresenter do
  let(:seller) { create(:user) }
  let!(:utm_link1) { create(:utm_link, seller:, unique_clicks: 3) }
  let!(:utm_link2) { create(:utm_link, seller:, unique_clicks: 1) }
  let!(:utm_link3) { create(:utm_link, seller:, unique_clicks: 2) }
  let!(:another_seller_utm_link) { create(:utm_link, unique_clicks: 1) }
  let(:product) { create(:product, user: seller) }
  let(:purchase1) { create(:purchase, price_cents: 1000, seller:, link: product) }
  let(:purchase2) { create(:purchase, price_cents: 2000, seller:, link: product) }
  let(:purchase3) { create(:purchase, price_cents: 0, seller:, link: product) }
  let(:test_purchase) { create(:test_purchase, price_cents: 3000, seller:, link: product) }
  let(:failed_purchase) { create(:failed_purchase, price_cents: 1000, seller:, link: product) }
  let!(:utm_link1_driven_sale1) { create(:utm_link_driven_sale, utm_link: utm_link1, purchase: purchase1) }
  let!(:utm_link1_driven_sale2) { create(:utm_link_driven_sale, utm_link: utm_link1, purchase: purchase2) }
  let!(:utm_link2_driven_sale1) { create(:utm_link_driven_sale, utm_link: utm_link2, purchase: purchase3) }
  let!(:utm_link2_driven_sale2) { create(:utm_link_driven_sale, utm_link: utm_link2, purchase: test_purchase) }
  let!(:utm_link2_driven_sale3) { create(:utm_link_driven_sale, utm_link: utm_link2, purchase: failed_purchase) }

  before do
    Feature.activate_user(:utm_links, seller)
  end

  describe "#props" do
    it "returns stats for the requested UTM link IDs" do
      props = described_class.new(seller:, utm_link_ids: [utm_link1.id, utm_link2.id, utm_link3.id, another_seller_utm_link.id]).props
      expect(props).to eq({
                            utm_link1.external_id => { sales_count: 2, revenue_cents: 3000, conversion_rate: 0.6667 },
                            utm_link2.external_id => { sales_count: 1, revenue_cents: 0, conversion_rate: 1.0 },
                            utm_link3.external_id => { sales_count: 0, revenue_cents: 0, conversion_rate: 0.0 },
                          })
    end
  end
end
