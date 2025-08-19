# frozen_string_literal: true

require("spec_helper")

describe("Purchase from a product page", type: :system, js: true) do
  before do
    @creator = create(:named_user)
    @product = create(:product, user: @creator)
  end

  it "displays card expired error if input card is expired as per stripe" do
    visit "/l/#{@product.unique_permalink}"

    add_to_cart(@product)
    check_out(@product, credit_card: { number: "4000000000000069" }, error: "Your card has expired.")

    expect(Purchase.last.stripe_error_code).to eq("expired_card")
  end

  it "displays insufficient funds error if input card does not have sufficient funds as per stripe" do
    visit "/l/#{@product.unique_permalink}"

    add_to_cart(@product)
    check_out(@product, credit_card: { number: "4000000000009995" }, error: "Your card has insufficient funds.")

    expect(Purchase.last.stripe_error_code).to eq("card_declined_insufficient_funds")
  end

  it "displays incorrect cvc error if input cvc is incorrect as per stripe" do
    visit "/l/#{@product.unique_permalink}"

    add_to_cart(@product)
    check_out(@product, credit_card: { number: "4000000000000127" }, error: "Your card's security code is incorrect.")

    expect(Purchase.last.stripe_error_code).to eq("incorrect_cvc")
  end

  it "displays card processing error if stripe reports a processing error" do
    visit "/l/#{@product.unique_permalink}"

    add_to_cart(@product)
    check_out(@product, credit_card: { number: "4000000000000119" }, error: "An error occurred while processing your card. Try again in a little bit.")

    expect(Purchase.last.stripe_error_code).to eq("processing_error")
  end

  it "lets use a different card after first having used an invalid card" do
    visit "/l/#{@product.unique_permalink}"

    add_to_cart(@product)
    check_out(@product, credit_card: { number: "4000000000009995" }, error: "Your card has insufficient funds.")

    expect(Purchase.last.stripe_error_code).to eq("card_declined_insufficient_funds")

    visit current_path

    check_out(@product)
    expect(page).not_to have_alert
  end

  it "doesn't allow purchase when the card information is incomplete" do
    visit @product.long_url
    add_to_cart(@product)

    fill_in "ZIP code", with: "94107"

    fill_in_credit_card(number: "", expiry: "", cvc: "")
    click_on "Pay"
    expect(page).to have_selector("[aria-label='Card information'][aria-invalid='true']")

    fill_in_credit_card(expiry: "", cvc: "")
    click_on "Pay"
    expect(page).to have_selector("[aria-label='Card information'][aria-invalid='true']")

    fill_in_credit_card(cvc: "")
    click_on "Pay"
    expect(page).to have_selector("[aria-label='Card information'][aria-invalid='true']")

    check_out(@product)
  end

  context "when the price changes while the product is in the cart" do
    it "fails the purchase but updates the product data" do
      visit @product.long_url
      add_to_cart(@product)
      @product.price_cents += 100
      check_out(@product, error: "The price just changed! Refresh the page for the updated price.")
      visit checkout_index_path
      check_out(@product)

      expect(Purchase.last.price_cents).to eq(200)
      expect(Purchase.last.was_product_recommended).to eq(false)
    end
  end

  it "focuses the correct fields with errors" do
    product = create(:physical_product, user: @creator)

    # Pass-through the params to bypass address verification
    allow_any_instance_of(ShipmentsController).to receive(:verify_shipping_address) do |controller|
      controller.render json: { success: true, **controller.params.permit! }
    end

    visit product.long_url
    add_to_cart(product)

    click_on "Pay"
    within_fieldset "Card information" do
      within_frame { expect_focused find_field("Card number") }
    end

    fill_in_credit_card(expiry: nil, cvc: nil)
    click_on "Pay"
    within_fieldset "Card information" do
      within_frame { expect_focused find_field("MM / YY") }
    end

    fill_in_credit_card(cvc: nil)
    click_on "Pay"
    within_fieldset "Card information" do
      within_frame { expect_focused find_field("CVC") }
    end

    fill_in_credit_card
    click_on "Pay"
    expect_focused find_field("Your email address")

    fill_in "Your email address", with: "gumroad@example.com"
    click_on "Pay"
    expect_focused find_field("Full name")

    fill_in "Full name", with: "G McGumroadson"
    click_on "Pay"
    expect_focused find_field("Street address")

    fill_in "Street address", with: "123 Main St"
    click_on "Pay"
    expect_focused find_field("City")

    fill_in "City", with: "San Francisco"
    click_on "Pay"
    expect_focused find_field("ZIP code")
  end
end
