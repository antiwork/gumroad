# frozen_string_literal: true

require("spec_helper")

describe("Product page sales count", js: true, type: :system) do
  before(:each) do
    @user = create(:user)
    @product = create(:product, user: @user, should_show_sales_count: true, price_cents: 100)

    recreate_model_index(Purchase)
  end

  it "hides the sales count when the flag is false" do
    @product.update! should_show_sales_count: false

    visit @product.long_url
    expect(page).to_not have_selector("[role='status']")
  end

  it "shows the sales count when the flag is true" do
    visit @product.long_url
    expect(page).to have_text("0 sales")
  end

  it "shows preorders count when the product is in preorder state" do
    product_with_preorder = create(:product, user: @user, is_in_preorder_state: true, should_show_sales_count: true)
    create(:preorder_link, link: product_with_preorder)

    visit product_with_preorder.long_url
    expect(page).to have_text("0 pre-orders")
  end

  describe "shows correct calculation and pluralization", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    it "includes free purchases in sales count" do
      @product.update! price_cents: 0

      create(:free_purchase, link: @product, succeeded_at: 1.hour.ago)

      visit @product.long_url
      expect(page).to have_text("1 download")

      @versioned_product = create(:product_with_digital_versions, should_show_sales_count: true)
      create(:free_purchase, link: @versioned_product, succeeded_at: 1.hour.ago)
      visit @product.long_url
      expect(page).to have_text("1 download")
    end

    it "includes free purchases for free PWYW sales count" do
      @product.update! price_cents: 0

      create(:free_purchase, link: @product, succeeded_at: 1.hour.ago)
      create(:purchase, link: @product, succeeded_at: 1.hour.ago)

      visit @product.long_url
      expect(page).to have_text("2 downloads")
    end

    it "excludes failed purchases from sales count" do
      create(:failed_purchase, link: @product, succeeded_at: 1.hour.ago)

      visit @product.long_url
      expect(page).to have_text("0 sales")
    end

    it "excludes fully refunded purchases from sales count" do
      create(:refunded_purchase, link: @product, succeeded_at: 1.hour.ago)

      visit @product.long_url
      expect(page).to have_text("0 sales")
    end

    it "excludes disputed purchases not won from sales count" do
      create(:disputed_purchase, :with_dispute, link: @product, succeeded_at: 1.hour.ago)

      visit @product.long_url
      expect(page).to have_text("0 sales")
    end

    it "pluralizes the label correctly" do
      recreate_model_index(Purchase)

      visit @product.long_url
      expect(page).to have_text("0 sales")

      create(:purchase, link: @product, succeeded_at: 1.hour.ago)
      visit @product.long_url
      expect(page).to have_text("1 sale")

      create(:purchase, link: @product, succeeded_at: 1.hour.ago)
      visit @product.long_url
      expect(page).to have_text("2 sales")
    end
  end

  context "free products with variants", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    before do
      @product = create(:product, user: @user, should_show_sales_count: true, price_cents: 0)
      create(:free_purchase, link: @product, succeeded_at: 1.hour.ago)
    end

    it "includes free purchases with free variants" do
      visit @product.long_url
      expect(page).to have_text("1 download")
    end

    it "includes free purchases with paid variants" do
      category = create(:variant_category, link: @product)
      create(:variant, variant_category: category, price_difference_cents: 200)

      create(:purchase, link: @product, succeeded_at: 1.hour.ago, price_cents: 200)

      visit @product.long_url
      expect(page).to have_text("2 sales")
    end
  end
end
