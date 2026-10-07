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

    it "displays the existing purchase stack with the review form" do
      login_as user
      visit bundle.long_url

      within_section "You've purchased this bundle" do
        expect(page).to have_link("View content", href: url_redirect.download_page_url)
        # Bundle buyers can now review the bundle itself (gumroad-private#1213),
        # so the purchase stack shows the rating prompt like any other product.
        expect(page).to have_text("Liked it? Give it a rating")
      end
    end
  end

  it "shows content missed by a partial update in the buyer's library after retrying" do
    buyer = create(:user)
    purchase = create(:purchase, link: bundle, purchaser: buyer, is_bundle_purchase: true, created_at: 3.days.ago)
    missing_product = create(:product, user: seller, name: "New workbook")
    create(:bundle_product, bundle:, product: missing_product, updated_at: 2.days.ago)
    bundle_product.update!(updated_at: 3.days.ago)
    versioned_bundle_product.update!(updated_at: 2.days.ago)
    travel_to(3.days.ago) do
      Purchase::CreateBundleProductPurchaseService.new(purchase, bundle_product).perform
    end
    travel_to(1.day.ago) do
      Purchase::CreateBundleProductPurchaseService.new(purchase, versioned_bundle_product).perform
    end
    login_as buyer
    visit library_path(bundles: bundle.external_id)
    expect(page).to have_product_card(product)
    expect(page).to have_product_card(versioned_product)
    expect(page).not_to have_product_card(missing_product)

    UpdateBundlePurchasesContentJob.new.perform(bundle.id)
    visit library_path(bundles: bundle.external_id)

    missing_purchase = purchase.product_purchases.find_by!(link: missing_product)
    expect(missing_purchase).to be_successful
    expect(page).to have_product_card(product)
    expect(page).to have_product_card(versioned_product)
    within find_product_card(missing_product) do
      expect(page).to have_link(missing_product.name, href: missing_purchase.url_redirect.download_page_url)
    end
  end
end
