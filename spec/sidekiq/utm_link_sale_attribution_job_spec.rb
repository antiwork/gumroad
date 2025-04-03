# frozen_string_literal: true

require "spec_helper"

describe UtmLinkSaleAttributionJob do
  let(:browser_guid) { "test_browser_guid" }
  let(:seller) { create(:user) }
  let!(:product) { create(:product, user: seller) }
  let!(:utm_link) { create(:utm_link, seller:) }
  let!(:order) { create(:order) }

  before do
    Feature.activate_user(:utm_links, seller)
  end

  it "attributes purchases to utm link visits within the attribution window" do
    purchase = create(:purchase, link: product, seller:)
    order.purchases << purchase
    visit = create(:utm_link_visit, utm_link:, browser_guid:, created_at: 6.days.ago)

    described_class.new.perform(order.id, browser_guid)

    driven_sale = utm_link.utm_link_driven_sales.sole
    expect(driven_sale.purchase_id).to eq(purchase.id)
    expect(driven_sale.utm_link_visit_id).to eq(visit.id)
  end

  it "does not attribute purchases to visits outside the attribution window" do
    purchase = create(:purchase, link: product, seller:)
    order.purchases << purchase
    create(:utm_link_visit, utm_link:, browser_guid:, created_at: 8.days.ago)

    expect do
      described_class.new.perform(order.id, browser_guid)
    end.not_to change { utm_link.utm_link_driven_sales.count }
  end

  it "only attributes purchases to the latest visit per utm link" do
    purchase = create(:purchase, link: product, seller:)
    order.purchases << purchase
    _old_visit = create(:utm_link_visit, utm_link:, browser_guid:, created_at: 6.days.ago)
    latest_visit = create(:utm_link_visit, utm_link:, browser_guid:, created_at: 1.day.ago)

    described_class.new.perform(order.id, browser_guid)

    driven_sale = utm_link.utm_link_driven_sales.sole
    expect(driven_sale.purchase_id).to eq(purchase.id)
    expect(driven_sale.utm_link_visit_id).to eq(latest_visit.id)
  end

  it "only attributes purchases to visits with matching browser guid" do
    purchase = create(:purchase, link: product, seller:)
    order.purchases << purchase
    create(:utm_link_visit, utm_link:, browser_guid: "different_guid", created_at: 1.day.ago)

    described_class.new.perform(order.id, browser_guid)

    expect(utm_link.utm_link_driven_sales.count).to eq(0)
  end

  it "only attributes successful purchases" do
    successful_purchase = create(:purchase, link: product, seller:)
    failed_purchase = create(:failed_purchase, link: product, seller:)
    unqualified_purchase = create(:purchase)
    order.purchases << [successful_purchase, failed_purchase, unqualified_purchase]
    visit = create(:utm_link_visit, utm_link:, browser_guid:, created_at: 1.day.ago)

    described_class.new.perform(order.id, browser_guid)

    driven_sale = utm_link.utm_link_driven_sales.sole
    expect(driven_sale.purchase_id).to eq(successful_purchase.id)
    expect(driven_sale.utm_link_visit_id).to eq(visit.id)
  end

  context "when utm link targets specific product" do
    let(:target_product) { create(:product, user: seller) }
    let(:other_product) { create(:product, user: seller) }
    let(:utm_link) { create(:utm_link, seller:, target_resource_id: target_product.id, target_resource_type: "product_page") }

    it "only attributes purchases for the targeted product" do
      target_purchase = create(:purchase, link: target_product, seller:)
      other_purchase = create(:purchase, link: other_product, seller:)
      order.purchases << [target_purchase, other_purchase]
      visit = create(:utm_link_visit, utm_link:, browser_guid:, created_at: 1.day.ago)

      described_class.new.perform(order.id, browser_guid)

      driven_sale = utm_link.utm_link_driven_sales.sole
      expect(driven_sale.purchase_id).to eq(target_purchase.id)
      expect(driven_sale.utm_link_visit_id).to eq(visit.id)
    end
  end

  context "when feature flag is disabled" do
    before do
      Feature.deactivate_user(:utm_links, seller)
    end

    it "does not attribute any purchases" do
      purchase = create(:purchase, link: product, seller:)
      order.purchases << purchase
      create(:utm_link_visit, utm_link:, browser_guid:, created_at: 1.day.ago)

      expect do
        described_class.new.perform(order.id, browser_guid)
      end.not_to change { utm_link.utm_link_driven_sales.count }
    end
  end

  context "when visit has no country code" do
    it "sets country code from purchase" do
      purchase = create(:purchase, link: product, seller:, country: "Australia")
      order.purchases << purchase
      visit = create(:utm_link_visit, utm_link:, browser_guid:, created_at: 1.day.ago, country_code: nil)

      described_class.new.perform(order.id, browser_guid)

      expect(visit.reload.country_code).to eq("AU")
    end
  end

  context "when visit already has country code" do
    it "preserves existing country code" do
      purchase = create(:purchase, link: product, seller:, country: "United States")
      order.purchases << purchase
      visit = create(:utm_link_visit, utm_link:, browser_guid:, created_at: 1.day.ago, country_code: "JP")

      described_class.new.perform(order.id, browser_guid)

      expect(visit.reload.country_code).to eq("JP")
    end
  end

  context "when visit was already attributed to a purchase" do
    it "attributes a new purchase to the same visit" do
      purchase = create(:purchase, link: product, seller:)
      order.purchases << purchase
      visit = create(:utm_link_visit, utm_link:, browser_guid:, created_at: 1.day.ago)
      create(:utm_link_driven_sale, utm_link:, utm_link_visit: visit, purchase:)
      new_purchase = create(:purchase, link: product, seller:)
      new_order = create(:order, purchases: [new_purchase])

      expect do
        described_class.new.perform(new_order.id, browser_guid)
      end.to change { utm_link.utm_link_driven_sales.count }.from(1).to(2)

      driven_sale = utm_link.utm_link_driven_sales.last
      expect(driven_sale.purchase_id).to eq(new_purchase.id)
      expect(driven_sale.utm_link_visit_id).to eq(visit.id)
    end
  end

  context "when multiple visits of different utm links qualify for the same purchase" do
    it "attributes the purchase to only one visit which is the most recent among all applicable links" do
      purchase = create(:purchase, link: product, seller:)
      order.purchases << purchase
      utm_link1_visit = create(:utm_link_visit, utm_link:, browser_guid:, created_at: 1.day.ago)

      utm_link2 = create(:utm_link, seller:)
      create(:utm_link_visit, utm_link: utm_link2, browser_guid:, created_at: 2.day.ago)

      expect do
        described_class.new.perform(order.id, browser_guid)
      end.to change { UtmLinkDrivenSale.count }.from(0).to(1)

      driven_sale = UtmLinkDrivenSale.sole
      expect(driven_sale.purchase_id).to eq(purchase.id)
      expect(driven_sale.utm_link_visit_id).to eq(utm_link1_visit.id)
      expect(driven_sale.utm_link_id).to eq(utm_link.id)
    end
  end
end
