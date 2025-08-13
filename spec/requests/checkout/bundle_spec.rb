# frozen_string_literal: true

require "spec_helper"

describe "Checkout bundles", :js, type: :feature do
  let(:seller) { create(:named_seller) }
  let(:bundle) { create(:product, user: seller, is_bundle: true, price_cents: 1000) }

  let(:product) { create(:product, user: seller, name: "Product", price_cents: 500) }
  let!(:bundle_product) { create(:bundle_product, bundle:, product:) }

  let(:versioned_product) { create(:product_with_digital_versions, user: seller, name: "Versioned product") }
  let!(:versioned_bundle_product) { create(:bundle_product, bundle:, product: versioned_product, variant: versioned_product.alive_variants.first, quantity: 3) }

  before do
    product.product_files << create(:readable_document, pdf_stamp_enabled: true)
  end

  it "allows purchasing the bundle" do
    visit bundle.long_url
    add_to_cart(bundle)

    within_cart_item "This bundle contains..." do
      within_cart_item "Product" do
        expect(page).to have_text("Qty: 1")
      end
      within_cart_item "Versioned product" do
        expect(page).to have_text("Qty: 3")
        expect(page).to have_text("Version: Untitled 1")
      end
    end

    fill_checkout_form(bundle)
    click_on "Pay"
    expect(page).to have_alert(text: "Your purchase was successful!")

    expect(page).to_not have_link("Product")
    expect(page).to have_section("Product")
    expect(page).to have_link("Versioned product - Untitled 1", href: Purchase.last.url_redirect.download_page_url)
    expect(page).to_not have_link("Bundle")
  end

  context "when the buyer is logged in" do
    it "redirects to the library after purchase" do
      buyer = create(:buyer_user)
      login_as buyer
      visit bundle.long_url
      add_to_cart(bundle)
      fill_checkout_form(bundle, logged_in_user: buyer)
      click_on "Pay"
      expect(page).to have_alert(text: "Your purchase was successful!")

      expect(page.current_url).to eq(library_url({ bundles: Purchase.first.external_id, host: UrlService.domain_with_protocol }))
    end
  end

  context "when the bundle changes mid-purchase" do
    it "displays an error and allows purchase on retry" do
      visit bundle.long_url
      add_to_cart(bundle)
      versioned_bundle_product.update!(quantity: 2)
      check_out(bundle, error: true)
      expect(page).to have_alert(text: "The bundle's contents have changed. Please refresh the page!")
      visit current_path
      fill_checkout_form(bundle)
      click_on "Pay"
      expect(page).to have_alert(text: "Your purchase was successful!")
    end
  end

  context "when the bundle has a physical product" do
    let(:physical_bundle) { create(:product, :bundle, user: seller) }

    let(:physical_product) { create(:physical_product, user: seller, name: "Physical product", skus: [create(:sku)]) }
    let!(:physical_bundle_product) { create(:bundle_product, bundle: physical_bundle, product: physical_product, variant: physical_product.skus.first, quantity: 3) }

    it "collects the shipping information" do
      visit physical_bundle.long_url
      add_to_cart(physical_bundle)
      fill_checkout_form(physical_bundle, address: { street: "2031 7th Ave", state: "WA", city: "Seattle", zip_code: "98121" })
      click_on "Pay"
      expect(page).to have_alert(text: "Your purchase was successful!")

      purchase = Purchase.last
      expect(purchase.street_address).to eq("2031 7TH AVE")
      expect(purchase.city).to eq("SEATTLE")
      expect(purchase.state).to eq("WA")
      expect(purchase.zip_code).to eq("98121")
    end
  end

  context "when the bundle products have custom fields" do
    let(:custom_fields_bundle) { create(:product, :with_custom_fields, is_bundle: true, user: seller, name: "Bundle") }
    let(:product1) { create(:product, :with_custom_fields, user: seller, name: "Product 1") }
    let!(:product1_bundle_product) { create(:bundle_product, bundle: custom_fields_bundle, product: product1) }
    let(:product2) { create(:product, :with_custom_fields, user: seller, name: "Product 2") }
    let!(:product2_bundle_product) { create(:bundle_product, bundle: custom_fields_bundle, product: product2) }

    it "records custom fields for all bundle products" do
      visit custom_fields_bundle.long_url
      add_to_cart(custom_fields_bundle)
      fill_checkout_form(custom_fields_bundle)
      click_on "Pay"
      within "[aria-label='Payment form']" do
        within_section "Bundle" do
          fill_in "Text field", aria: { invalid: "false" }, with: "Bundle"
          check "Checkbox field", aria: { invalid: "true" }
          check "I accept", aria: { invalid: "true" }
        end
        within_section "Product 1" do
          fill_in "Text field", aria: { invalid: "false" }, with: "Product 1"
          check "Checkbox field", aria: { invalid: "true" }
          check "I accept", aria: { invalid: "true" }
        end
        within_section "Product 2" do
          fill_in "Text field", aria: { invalid: "false" }, with: "Product 2"
          check "Checkbox field", aria: { invalid: "true" }
          check "I accept", aria: { invalid: "true" }
        end
      end

      click_on "Pay"
      expect(page).to have_alert(text: "Your purchase was successful!")

      bundle_purchase = Purchase.third_to_last
      expect(bundle_purchase).to be_successful
      expect(bundle_purchase.custom_fields).to eq(
        [
          { name: "Text field", value: "Bundle", type: CustomField::TYPE_TEXT },
          { name: "Checkbox field", value: true, type: CustomField::TYPE_CHECKBOX },
          { name: "http://example.com", value: true, type: CustomField::TYPE_TERMS },
        ]
      )
      product1_purchase = Purchase.second_to_last
      expect(product1_purchase).to be_successful
      expect(product1_purchase.custom_fields).to eq(
        [
          { name: "Text field", value: "Product 1", type: CustomField::TYPE_TEXT },
          { name: "Checkbox field", value: true, type: CustomField::TYPE_CHECKBOX },
          { name: "http://example.com", value: true, type: CustomField::TYPE_TERMS },
        ]
      )
      product2_purchase = Purchase.last
      expect(product2_purchase).to be_successful
      expect(product2_purchase.custom_fields).to eq(
        [
          { name: "Text field", value: "Product 2", type: CustomField::TYPE_TEXT },
          { name: "Checkbox field", value: true, type: CustomField::TYPE_CHECKBOX },
          { name: "http://example.com", value: true, type: CustomField::TYPE_TERMS },
        ]
      )
    end
  end

  context "gifting bundles with license keys" do
    let(:bundle_with_licensed_product) { create(:product, user: seller, is_bundle: true) }
    let(:licensed_product) { create(:product, user: seller, name: "Licensed product", is_licensed: true) }
    let!(:licensed_bundle_product) { create(:bundle_product, bundle: bundle_with_licensed_product, product: licensed_product) }
    let(:giftee_email) { "giftee@gumroad.com" }

    it "only generates a license key for the giftee" do
      visit bundle_with_licensed_product.long_url
      add_to_cart(bundle_with_licensed_product)
      check_out(bundle_with_licensed_product, gift: { email: giftee_email, note: "Gifting licensed bundle!" })

      expect(Purchase.all_success_states.count).to eq 4
      expect(Gift.successful.where(link_id: bundle_with_licensed_product.id, gifter_email: "test@gumroad.com", giftee_email:).count).to eq 1

      gifter_purchase = bundle_with_licensed_product.sales.is_gift_sender_purchase.sole
      giftee_purchase = bundle_with_licensed_product.sales.is_gift_receiver_purchase.sole

      expect(gifter_purchase.product_purchases.sole.license).to be_nil
      expect(giftee_purchase.product_purchases.sole.license).to_not be_nil
      expect(giftee_purchase.product_purchases.sole.license_key).to be_present

      # Both sender and receiver receipts should load properly
      visit gifter_purchase.receipt_url
      expect(page).to have_text("Gift sent to")

      visit giftee_purchase.receipt_url
      expect(page).to have_text("You've received a gift!")
    end
  end

  context "test purchase" do
    it "displays the temporary library on purchase" do
      login_as seller
      visit bundle.long_url
      add_to_cart(bundle)
      fill_in "ZIP code", with: "12345"
      click_on "Pay"
      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to seller@example.com.")

      purchases = Purchase.last(3)
      purchases.each do |purchase|
        expect(purchase.purchase_state).to eq("test_successful")
        expect(purchase.is_test_purchase?).to eq(true)
      end

      expect(page).to_not have_link("Product")
      expect(page).to have_section("Product")
      expect(page).to have_link("Versioned product - Untitled 1", href: purchases.last.url_redirect.download_page_url)
    end
  end
end
