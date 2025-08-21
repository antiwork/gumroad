# frozen_string_literal: true

require("spec_helper")

describe("The supporter count", js: true, type: :system) do
  before do
    recreate_model_indices(Purchase)
    @user = create(:user)
    @product = create(:membership_product, user: @user, should_show_sales_count: true)
  end

  it "doesn't show the supporter count when the flag is false" do
    product = create(:membership_product, user: @user, should_show_sales_count: false)

    visit("l/#{product.unique_permalink}")
    expect(page).not_to have_text("0 members")
  end

  it "shows the supporter count when the flag is true" do
    @product.should_show_sales_count = true

    visit("l/#{@product.unique_permalink}")
    expect(page).to have_text("0 members")
  end

  describe "shows correct calculation and pluralization", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    it "includes free membership purchases in sales count" do
      product = create(:membership_product, user: @user, should_show_sales_count: true)
      create(:membership_purchase, link: product, succeeded_at: 1.hour.ago, price_cents: 0)

      visit("l/#{product.unique_permalink}")
      expect(page).to have_text("1 member")
    end

    it "includes paid membership purchases in sales count" do
      product = create(:membership_product, user: @user, should_show_sales_count: true)
      create(:membership_purchase, link: product, succeeded_at: 1.hour.ago, price_cents: 100)

      visit("l/#{product.unique_permalink}")
      expect(page).to have_text("1 member")
    end

    it "pluralizes the label correctly" do
      recreate_model_index(Purchase)

      product = create(:membership_product, user: @user, should_show_sales_count: true)

      visit("/l/#{product.unique_permalink}")
      expect(page).to have_text("0 members")

      create(:membership_purchase, link: product, succeeded_at: 1.hour.ago, price_cents: 100)
      visit("/l/#{product.unique_permalink}")
      expect(page).to have_text("1 member")

      create(:membership_purchase, link: product, succeeded_at: 1.hour.ago, price_cents: 100)
      visit("/l/#{product.unique_permalink}")
      expect(page).to have_text("2 members")
    end
  end
end
