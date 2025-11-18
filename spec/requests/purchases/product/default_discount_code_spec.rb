# frozen_string_literal: true

require("spec_helper")

describe("Default discount code usage from product page", type: :system, js: true) do
  let(:seller) { create(:user, display_offer_code_field: true) }
  let(:product) { create(:product_with_pdf_file, user: seller, price_cents: 1000) }
  # Use a percentage offer code factory so we don't inherit any fixed amount_cents
  let(:default_offer_code) do
    create(:percentage_offer_code, user: seller, products: [product], code: "DEFAULT10", amount_percentage: 10)
  end

  before do
    allow(Braintree::ClientToken).to receive(:generate).and_return("test_client_token_12345")
  end

  it "applies default discount code automatically when user visits product page" do
    visit "/l/#{product.unique_permalink}"

    expect(page).to have_content(product.name)
    # Verify the discounted price is displayed
    expect(page).to have_selector("[itemprop='price']", text: "$10 $9", visible: false)

    # Verify discount is applied on checkout page
    add_to_cart(product)
    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    expect(page).to have_selector("[aria-label='Discount code']", text: default_offer_code.code, wait: 5)
    expect(page).to have_text("Total US$9", normalize_ws: true, wait: 5)
  end

  it "allows user to override default discount code with URL discount code" do
    url_offer_code = create(
      :percentage_offer_code,
      user: seller,
      products: [product],
      code: "URL20",
      amount_percentage: 20
    )
    visit "/l/#{product.unique_permalink}/#{url_offer_code.code}"

    # Wait for page to load
    expect(page).to have_content(product.name)

    # Verify URL discount code is applied on checkout page (not the default)
    # The URL code (20% off) should result in $8 total, not the default (10% off) which would be $9
    add_to_cart(product, offer_code: url_offer_code)
    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    # Verify the URL code is shown (not the default code)
    expect(page).to have_selector("[aria-label='Discount code']", text: url_offer_code.code, wait: 5)
    # Verify the URL code discount is applied (20% off $10 = $8)
    # Note: The discount calculation should use the URL code's 20% discount, not the default's 10%
    expect(page).to have_text("Total US$8", normalize_ws: true, wait: 5)
  end

  it "applies default discount code with fixed amount discount" do
    fixed_offer_code = create(
      :offer_code,
      user: seller,
      products: [product],
      code: "DEFAULT5",
      amount_cents: 500,
      amount_percentage: nil
    )
    product.update!(default_offer_code: fixed_offer_code)

    visit "/l/#{product.unique_permalink}"

    expect(page).to have_content(product.name)
    expect(page).to have_selector("[itemprop='price']", text: "$10 $5", visible: false)

    # Verify fixed amount discount is applied on checkout page
    add_to_cart(product)
    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    expect(page).to have_selector("[aria-label='Discount code']", text: fixed_offer_code.code, wait: 5)
    expect(page).to have_text("Total US$5", normalize_ws: true, wait: 5)
  end

  context "with minimum quantity requirement" do
    before do
      product.update!(quantity_enabled: true)
      default_offer_code.update!(minimum_quantity: 2)
    end

    it "applies default discount code when minimum quantity is met" do
      visit "/l/#{product.unique_permalink}"

      expect(page).to have_content(product.name)
      expect(page).to have_field("Quantity")

      fill_in "Quantity", with: "2"
      # Wait for React to update the price based on quantity
      wait_for_ajax
      # Verify the discounted price is displayed for quantity 2 (2 * $10 = $20, 10% off = $18)
      expect(page).to have_selector("[itemprop='price']", text: "$20 $18", visible: false, wait: 10)

      # Verify discount is applied on checkout page for quantity 2
      add_to_cart(product, quantity: 2)
      expect(page).to have_current_path(/^\/checkout/, wait: 10)
      expect(page).to have_selector("[aria-label='Discount code']", text: default_offer_code.code, wait: 5)
      expect(page).to have_text("Total US$18", normalize_ws: true, wait: 5)
    end
  end

  context "with universal offer code" do
    let(:default_offer_code) do
      create(:universal_offer_code, user: seller, code: "UNIVERSAL10", amount_cents: nil, amount_percentage: 10)
    end

    it "applies universal default discount code automatically" do
      visit "/l/#{product.unique_permalink}"

      expect(page).to have_content(product.name)
      expect(page).to have_selector("[itemprop='price']", text: "$10 $9", visible: false)

      # Verify universal discount is applied on checkout page
      add_to_cart(product)
      expect(page).to have_current_path(/^\/checkout/, wait: 10)
      expect(page).to have_selector("[aria-label='Discount code']", text: default_offer_code.code, wait: 5)
      expect(page).to have_text("Total US$9", normalize_ws: true, wait: 5)
    end
  end
end
