# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Admin Pages Scenario", type: :system, js: true do
  let(:admin) { create(:named_user, :admin, has_risk_privilege: true) }

  before do
    allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
    login_as(admin)
  end

  describe "Navigation" do
    context "with switching account to user as admin for seller" do
      let(:seller) { create(:named_seller) }

      include_context "with switching account to user as admin for seller" do
        let(:user_with_role_for_seller) { admin }
      end

      it "uses logged_in_user for navigation" do
        purchase = create(:purchase)
        visit admin_purchase_path(purchase)

        wait_for_ajax
        expect(page).to have_content user_with_role_for_seller.name
      end
    end
  end

  describe "Purchase" do
    it "shows the correct currency symbol" do
      product = create(:product, price_cents: 649, price_currency_type: "aud", name: "Tim Tam")
      purchase = create(:purchase, link: product, displayed_price_currency_type: :aud)

      visit admin_purchase_path(purchase)

      expect(page).to have_text("A$6.49 for Tim Tam")
    end
  end

  describe "Search" do
    let(:purchase) { create(:purchase) }

    before do
      visit admin_purchase_path(purchase)
      select_disclosure "Toggle Search"
    end

    it "searches users by query field" do
      fill_in "Search users (email, name, ID)", with: "joe@example.com\n"
      expect(page).to have_current_path(admin_search_users_path(query: "joe@example.com"))
    end

    it "searches cards by all fields" do
      select("Visa", from: "card_type")
      fill_in("transaction_date", with: "02/22/2022")
      fill_in("last_4", with: "1234")
      fill_in("expiry_date", with: "02/22")
      fill_in("price", with: "9.99")
      click_on("Search")
      expect(page).to have_current_path(admin_cards_path, ignore_query: true)
      query_values = Addressable::URI.parse(page.current_url).query_values
      expect(query_values["card_type"]).to eq("visa")
      expect(query_values["transaction_date"]).to eq("02/22/2022")
      expect(query_values["last_4"]).to eq("1234")
      expect(query_values["expiry_date"]).to eq("02/22")
      expect(query_values["price"]).to eq("9.99")
    end

    it "allows admins to search purchases by email" do
      product = create(:product, price_cents: 600, price_currency_type: "eur")
      offer_code = create(:offer_code, products: [product], amount_cents: 200, max_purchase_count: 1, currency_type: "eur")
      email = "searchme@gumroad.com"
      purchase = create(:purchase,
                        link: product,
                        email:,
                        gumroad_tax_cents: 154,
                        displayed_price_currency_type: :eur,
                        rate_converted_to_usd: "0.86")
      offer_code.purchases << purchase

      visit admin_purchase_path(purchase)
      select_disclosure "Toggle Search"

      fill_in "Search purchases (email, IP, card, external ID)", with: "#{email}\n"

      expect(page).to have_selector("h2.purchase-title", text: "€6 + €1.32 VAT for #{product.name}")
    end

    it "allows admins to search purchases by credit card fingerprint" do
      purchase = create(:purchase, email: "foo@example.com", stripe_fingerprint: "FINGERPRINT_ONE")
      create(:purchase, email: "bar@example.com", stripe_fingerprint: "FINGERPRINT_ONE")
      create(:purchase, email: "baz@example.com", stripe_fingerprint: "FINGERPRINT_TWO")
      visit admin_purchase_path(purchase)
      click_link "VISA"
      expect(page).to have_content "foo@example.com"
      expect(page).to have_content "bar@example.com"
      expect(page).to have_no_content "baz@example.com"
    end

    it "shows external fingerprint link only for Stripe" do
      purchase = create(:purchase, stripe_fingerprint: "MY_FINGERPRINT")
      visit admin_purchase_path(purchase)
      expect(page).to have_content "MY_FINGERPRINT"

      purchase = create(:purchase, stripe_fingerprint: "MY_FINGERPRINT", charge_processor_id: BraintreeChargeProcessor.charge_processor_id)
      visit admin_purchase_path(purchase)
      expect(page).to have_no_content "MY_FINGERPRINT"
    end

    it "allows admins to page through purchase search results" do
      stub_const("#{Admin::SearchController}::RECORDS_PER_PAGE", 2)
      email = "searchme@gumroad.com"

      3.times do |i|
        link = create(:product, name: "product ##{i}")
        create(:purchase, link:, email:, created_at: Time.current + i.hours)
      end

      visit admin_purchase_path(purchase)
      select_disclosure "Toggle Search"

      fill_in "Search purchases (email, IP, card, external ID)", with: "#{email}\n"

      expect(page).to have_text("product #2")
      expect(page).to have_text("product #1")

      click_on("Next")
      expect(page).to have_text("product #0")
    end
  end

  context "user products" do
    let(:creator) { create(:user) }

    it "displays product analytics stats", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      product = create(:product_with_pdf_file, user: creator)

      recreate_model_index(ProductPageView)
      2.times { add_page_view(product) }
      purchases = create_list(:purchase, 4, link: product)
      purchases.each do |purchase|
        create(:purchase_event, purchase:)
      end

      visit admin_user_path(creator)
      click_on "Products"

      expect(page).to have_text(product.name)
      expect(page).to have_text("2 views")
      expect(page).to have_text("4 sales")
    end
  end
end
