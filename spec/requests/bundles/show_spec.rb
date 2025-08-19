# frozen_string_literal: true

require "spec_helper"

describe("Bundle page", type: :system, js: true) do
  let(:seller) { create(:named_seller) }
  let(:bundle) { create(:product, user: seller, is_bundle: true, price_cents: 1000) }

  let(:product) { create(:product, user: seller, name: "Product", price_cents: 500) }
  let!(:bundle_product) { create(:bundle_product, bundle:, product:) }

  let(:versioned_product) { create(:product_with_digital_versions, user: seller, name: "Versioned product") }
  let!(:versioned_bundle_product) { create(:bundle_product, bundle:, product: versioned_product, variant: versioned_product.alive_variants.first, quantity: 3) }

  before do
    versioned_bundle_product.variant.update!(price_difference_cents: 400)
  end

  describe "price" do
    it "displays the standalone price and the bundle price" do
      visit bundle.long_url

      within first("[itemprop='price']") do
        expect(page).to have_selector("s", text: "$20")
        expect(page).to have_text("$10")
      end
    end

    context "when the bundle has a discount" do
      let(:offer_code) { create(:percentage_offer_code, user: seller, products: [bundle], amount_percentage: 50) }

      it "displays the standalone price and the discounted bundle price" do
        visit "#{bundle.long_url}/#{offer_code.code}"

        within first("[itemprop='price']") do
          expect(page).to have_selector("s", text: "$20")
          expect(page).to have_text("$5")
        end
      end
    end
  end

  it "displays the bundle products" do
    visit bundle.long_url

    within_section "This bundle contains..." do
      within_cart_item "Product" do
        expect(page).to have_link("Product", href: product.long_url)
        expect(page).to have_selector("[aria-label='Rating']", text: "0.0 (0)")
        expect(page).to have_selector("[aria-label='Price'] s", text: "$5")
        expect(page).to have_text("Qty: 1")
      end

      within_cart_item "Versioned product" do
        expect(page).to have_link("Versioned product", href: versioned_product.long_url)
        expect(page).to have_selector("[aria-label='Rating']", text: "0.0 (0)")
        expect(page).to have_selector("[aria-label='Price'] s", text: "$15")
        expect(page).to have_text("Qty: 3")
        expect(page).to have_text("Version: Untitled 1")
      end
    end
  end

  context "when the bundle has already been purchased" do
    let(:user) { create(:user) }
    let!(:url_redirect) { create(:url_redirect, purchase: create(:purchase, link: bundle, purchaser: user)) }

    it "displays the existing purchase stack" do
      login_as user
      visit bundle.long_url

      within_section "You've purchased this bundle" do
        expect(page).to have_link("View content", href: url_redirect.download_page_url)
        expect(page).to_not have_text("Liked it? Give it a rating")
      end
    end
  end
end
