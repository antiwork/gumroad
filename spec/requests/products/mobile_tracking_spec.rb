# frozen_string_literal: true

describe "Mobile tracking", type: :system, js: true do
  let(:product) { create(:product) }

  before do
    allow_any_instance_of(UsersHelper).to receive(:is_third_party_analytics_enabled?).and_return(true)
  end

  it "adds global functions the apps can call to track product events" do
    visit link_mobile_tracking_path(product.unique_permalink)

    expect(page.evaluate_script("typeof window.tracking.ctaClick")).to eq("function")
    expect(page.evaluate_script("typeof window.tracking.productPurchase")).to eq("function")
  end

  context "when the product has product third-party analytics" do
    before do
      create(:third_party_analytic, user: product.user, link: product, location: "product")
    end

    it "loads the third-party analytics iframe" do
      visit link_mobile_tracking_path(product.unique_permalink)

      expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{product.unique_permalink}']", visible: false)
    end
  end

  context "when the product has receipt third-party analytics" do
    before do
      create(:third_party_analytic, user: product.user, link: product, location: "receipt")
    end

    it "loads the third-party analytics iframe after purchase" do
      visit link_mobile_tracking_path(product.unique_permalink)

      expect(page).not_to have_selector("iframe", visible: false)

      page.execute_script("window.tracking.productPurchase({permalink: 'test', currency_type: 'usd'})")

      expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='test']", visible: false)
    end
  end
end
