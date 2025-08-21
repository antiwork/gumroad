# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("ProductMoreOptionScenario", type: :system, js: true) do
  include ProductEditPageHelpers

  def visit_product_edit(link)
    visit("/products/#{link.unique_permalink}/edit")
    wait_for_ajax
  end

  def visit_product_edit_checkout_tab(link)
    visit("/products/#{link.unique_permalink}/edit#checkout")
    wait_for_ajax
  end

  def shipping_rows
    within :section, "Shipping destinations", match: :first do
      all("[aria-label='Shipping destination']")
    end
  end

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product_with_pdf_file, user: seller) }

  include_context "with switching account to user as admin for seller"

  describe "variants & skus" do
    it "allows user to add and remove variants" do
      visit_product_edit(product)

      click_on "Add version"
      within version_rows.last do
        fill_in "Version name", with: "M"
      end

      expect do
        save_change
        product.reload
        product.variant_categories.reload
      end.to(change { product.variant_categories.alive.count }.by(1))
      expect(product.variant_categories.alive.first.variants.count).to eq 1

      within version_rows.last do
        within version_option_rows[0] do
          remove_version_option
        end
      end

      within_modal "Remove M?" do
        expect(page).to have_text("If you delete this version, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest version as a fallback. If no version exists, they will see the product-level content.")
        click_on "Yes, remove"
      end

      expect do
        save_change
        product.reload
      end.to(change { product.variant_categories.alive.count }.to(0))
    end

    it("accepts variants with % in their name") do
      visit_product_edit(product)

      click_on "Add version"
      within version_rows.last do
        fill_in "Version name", with: "99%"
      end

      save_change

      expect(product.reload.variant_categories.count).to eq 1
      variant_category = product.reload.variant_categories.last
      expect(variant_category.variants.count).to eq 1
      expect(variant_category.variants.last.name).to eq "99%"
    end
  end

  describe "shipping options" do
    before do
      product.is_physical = true
      product.require_shipping = true
      product.save!
    end

    it "does not show for non-physical products" do
      product.is_physical = false
      product.save!

      visit_product_edit(product)
      expect(page).to_not have_text("Shipping destinations")
      expect(page).to_not have_text("Add shipping destinations")
      expect(page).to_not have_text("Choose where you're able to ship your physical product to")
    end

    it "does not allow a save without any shipping options for a published product" do
      product.purchase_disabled_at = nil
      product.save!

      visit_product_edit(product)

      expect(page).to have_text("Add shipping destinations")
      expect(page).to have_text("Choose where you're able to ship your physical product to")

      save_change(expect_message: "The product needs to be shippable to at least one destination.")
    end

    it "allows shipping options to be saved" do
      visit_product_edit(product)

      expect(page).to have_text("Add shipping destinations")
      expect(page).to have_text("Choose where you're able to ship your physical product to")

      click_on("Add shipping destination")
      click_on("Add shipping destination")

      within shipping_rows[0] do
        page.select("United States", from: "Country")
        page.fill_in("Amount alone", with: "12")
        page.fill_in("Amount with others", with: "6")
      end

      within shipping_rows[1] do
        page.select("Germany", from: "Country")
        page.fill_in("Amount alone", with: "12")
        page.fill_in("Amount with others", with: "6")
      end

      save_change

      expect(page).to_not have_text("Add shipping destinations")
      expect(page).to_not have_text("Choose where you're able to ship your physical product to")

      product.reload
      expect(product.shipping_destinations.size).to eq(2)
      expect(product.shipping_destinations.alive.size).to eq(2)

      expect(product.shipping_destinations.first.country_code).to eq("US")
      expect(product.shipping_destinations.first.one_item_rate_cents).to eq(1200)
      expect(product.shipping_destinations.first.multiple_items_rate_cents).to eq(600)

      expect(product.shipping_destinations.second.country_code).to eq("DE")
      expect(product.shipping_destinations.second.one_item_rate_cents).to eq(1200)
      expect(product.shipping_destinations.second.multiple_items_rate_cents).to eq(600)
    end

    it "allows shipping options to be removed" do
      # Saved w/ a default shipping country due to validations, set it up to be as expected
      ShippingDestination.destroy_all

      shipping_destination1 = ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)
      shipping_destination2 = ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 0)

      product.shipping_destinations << shipping_destination1 << shipping_destination2

      visit_product_edit(product)
      expect(shipping_rows.size).to eq(2)

      expect(page).to_not have_text("Add shipping destinations")
      expect(page).to_not have_text("Choose where you're able to ship your physical product to")

      within shipping_rows[0] do
        page.select("Germany", from: "Country")
        page.fill_in("Amount alone", with: "0.10")
        page.fill_in("Amount with others", with: "0.05")
      end

      within shipping_rows[1] do
        page.select("Elsewhere", from: "Country")
        page.fill_in("Amount alone", with: "0.20")
        page.fill_in("Amount with others", with: "0")
      end

      within shipping_rows[0] do
        click_on "Remove shipping destination"
      end
      wait_for_ajax

      expect(shipping_rows.size).to eq(1)

      within shipping_rows[0] do
        expect(page).to have_field("Country", with: "ELSEWHERE")
        expect(page).to have_field("Amount alone", with: "0.20")
        expect(page).to have_field("Amount with others", with: "0")
      end

      save_change

      product.reload
      expect(product.shipping_destinations.size).to eq(2)
      expect(product.shipping_destinations.alive.size).to eq(1)

      expect(product.shipping_destinations.alive.first.country_code).to eq("ELSEWHERE")
      expect(product.shipping_destinations.alive.first.one_item_rate_cents).to eq(20)
      expect(product.shipping_destinations.alive.first.multiple_items_rate_cents).to eq(0)
    end

    describe "virtual countries" do
      it "allows shipping options to be saved" do
        visit_product_edit(product)

        expect(page).to have_text("Add shipping destinations")
        expect(page).to have_text("Choose where you're able to ship your physical product to")

        click_on("Add shipping destination")
        expect(shipping_rows.size).to eq(1)
        click_on("Add shipping destination")
        expect(shipping_rows.size).to eq(2)

        within shipping_rows[0] do
          page.select("Europe", from: "Country")
          page.fill_in("Amount alone", with: "12")
          page.fill_in("Amount with others", with: "6")
        end

        within shipping_rows[1] do
          page.select("Germany", from: "Country")
          page.fill_in("Amount alone", with: "12")
          page.fill_in("Amount with others", with: "6")
        end

        save_change

        expect(page).to_not have_text("Add shipping destinations")
        expect(page).to_not have_text("Choose where you're able to ship your physical product to")

        product.reload
        expect(product.shipping_destinations.size).to eq(2)
        expect(product.shipping_destinations.alive.size).to eq(2)

        expect(product.shipping_destinations.first.country_code).to eq("EUROPE")
        expect(product.shipping_destinations.first.one_item_rate_cents).to eq(1200)
        expect(product.shipping_destinations.first.multiple_items_rate_cents).to eq(600)

        expect(product.shipping_destinations.second.country_code).to eq("DE")
        expect(product.shipping_destinations.second.one_item_rate_cents).to eq(1200)
        expect(product.shipping_destinations.second.multiple_items_rate_cents).to eq(600)
      end

      it "allows shipping options to be removed" do
        # Saved w/ a default shipping country due to validations, set it up to be as expected
        ShippingDestination.all.each(&:destroy)

        shipping_destination1 = ShippingDestination.new(country_code: ShippingDestination::Destinations::ASIA, one_item_rate_cents: 10, multiple_items_rate_cents: 5, is_virtual_country: true)
        shipping_destination2 = ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 20, multiple_items_rate_cents: 0)

        product.shipping_destinations << shipping_destination1 << shipping_destination2

        visit_product_edit(product)

        expect(page).to_not have_text("Add shipping destinations")
        expect(page).to_not have_text("Choose where you're able to ship your physical product to")

        expect(shipping_rows.size).to eq(2)

        within shipping_rows[0] do
          expect(page).to have_field("Country", with: "ASIA")
          expect(page).to have_field("Amount alone", with: "0.10")
          expect(page).to have_field("Amount with others", with: "0.05")
        end

        within shipping_rows[1] do
          expect(page).to have_field("Country", with: "DE")
          expect(page).to have_field("Amount alone", with: "0.20")
          expect(page).to have_field("Amount with others", with: "0")
        end

        within shipping_rows[0] do
          click_on "Remove shipping destination"
        end

        expect(shipping_rows.size).to eq(1)

        within shipping_rows[0] do
          expect(page).to have_field("Country", with: "DE")
          expect(page).to have_field("Amount alone", with: "0.20")
          expect(page).to have_field("Amount with others", with: "0")
        end

        save_change

        product.reload
        expect(product.shipping_destinations.size).to eq(2)
        expect(product.shipping_destinations.alive.size).to eq(1)

        expect(product.shipping_destinations.alive.first.country_code).to eq("DE")
        expect(product.shipping_destinations.alive.first.one_item_rate_cents).to eq(20)
        expect(product.shipping_destinations.alive.first.multiple_items_rate_cents).to eq(0)
      end
    end
  end

  it "marks the product as e-publication" do
    visit_product_edit(product)

    check "Mark product as e-publication for VAT purposes"

    expect do
      save_change
    end.to change { product.reload.is_epublication }.from(false).to(true)
  end

  it "does not show e-publication toggle for physical product" do
    product = create(:physical_product, user: seller)

    visit_product_edit(product)

    expect(page).not_to have_text("Mark product as e-publication for VAT purposes")
  end

  describe "Refund policy" do
    before do
      seller.update!(refund_policy_enabled: false)
    end

    it "creates a refund policy" do
      visit_product_edit(product)

      check "Specify a refund policy for this product"

      expect(page).not_to have_text("Copy from other products")

      select "7-day money back guarantee", from: "Refund period"
      fill_in "Fine print (optional)", with: "This is the fine print"

      expect do
        save_change
      end.to change { product.reload.product_refund_policy_enabled }.from(false).to(true)
      refund_policy = product.product_refund_policy

      expect(refund_policy.title).to eq("7-day money back guarantee")
      expect(refund_policy.fine_print).to eq("This is the fine print")
    end

    context "with other refund policies" do
      let!(:other_refund_policy) { create(:product_refund_policy, product: create(:product, user: seller)) }

      it "allows copying a refund policy" do
        visit_product_edit(product)

        check "Specify a refund policy for this product"

        select_disclosure "Copy from other products" do
          select_combo_box_option(other_refund_policy.product.name)
          click_on("Copy")
        end

        expect do
          save_change
        end.to change { product.reload.product_refund_policy_enabled }.from(false).to(true)
        refund_policy = product.product_refund_policy

        expect(refund_policy.max_refund_period_in_days).to eq(other_refund_policy.max_refund_period_in_days)
        expect(refund_policy.title).to eq(other_refund_policy.title)
        expect(refund_policy.fine_print).to eq(other_refund_policy.fine_print)
      end
    end
  end
end
