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

    wait_until_true(sleep_interval: CheckoutPresenter::CART_SAVE_DEBOUNCE_DURATION_IN_SECONDS) { Cart.alive.where(email: "test@gumroad.com").exists? }
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
      wait_until_true(sleep_interval: CheckoutPresenter::CART_SAVE_DEBOUNCE_DURATION_IN_SECONDS) { Cart.alive.where(email: "test@gumroad.com").exists? }
      visit checkout_path
      check_out(@product)

      expect(Purchase.last.price_cents).to eq(200)
      expect(Purchase.last.was_product_recommended).to eq(false)
    end
  end

  it "focuses the correct fields with errors" do
    product = create(:physical_product, user: @creator)

    visit product.long_url
    add_to_cart(product)

    click_on "Pay"
    within_fieldset "Card information" do
      within_credit_card_frame { expect_focused find_field("Card number") }
    end

    fill_in_credit_card(expiry: nil, cvc: nil)
    click_on "Pay"
    within_fieldset "Card information" do
      within_credit_card_frame { expect_focused find_field("MM / YY") }
    end

    fill_in_credit_card(cvc: nil)
    click_on "Pay"
    within_fieldset "Card information" do
      within_credit_card_frame { expect_focused find_field("CVC") }
    end

    fill_in_credit_card
    click_on "Pay"
    expect_focused find_field("Email address")

    fill_in "Email address", with: "gumroad@example.com"
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

  describe "when the total is so small that Gumroad's fee leaves the seller no proceeds" do
    before do
      # A seller on a 100% custom fee with a minimum-priced product is the cheapest real
      # checkout shape whose fee (100% + fixed fee floor) meets or exceeds the whole total,
      # which makes the would-be seller transfer amount non-positive. The seller needs their
      # own (non-migrated) merchant account so the charge takes the destination-charge path,
      # where Stripe would otherwise reject `transfer_data[amount] < 1` with an opaque error.
      @creator.update!(custom_fee_per_thousand: 1000)
      create(:merchant_account, user: @creator)
      @product.update!(price_cents: 99)
      allow(ErrorNotifier).to receive(:notify)
    end

    it "fails the purchase with a clear 'total too small' error instead of the generic retry prompt" do
      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product)
      check_out(@product, error: "The purchase total is too small for us to process. Please add another item to your order or contact the creator.")

      purchase = Purchase.last
      expect(purchase.purchase_state).to eq("failed")
      expect(purchase.stripe_error_code).to eq(PurchaseErrorCode::NET_NEGATIVE_SELLER_REVENUE)
      # The guard raises before any PaymentIntent is submitted, so no charge exists.
      expect(purchase.stripe_transaction_id).to be_nil
    end
  end
end
