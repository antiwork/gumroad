# frozen_string_literal: true

require("spec_helper")

describe("New-customer-only offer codes from product page", type: :system, js: true) do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 3000, name: "Pro Membership") }
  let!(:offer_code) do
    create(:offer_code,
           user: seller,
           products: [product],
           new_customers_only: true,
           amount_cents: nil,
           amount_percentage: 20,
           currency_type: nil,
           code: "welcome20")
  end

  let(:refusal) { "This code is only for new customers of this store. The account or email used for this order has a previous purchase." }

  def expect_full_price
    expect(page).to have_content(product.name)
    expect(page).to have_selector("[itemprop='price']", text: "$30", visible: false)
  end

  def expect_new_customer_offer
    expect(page).to have_selector("[role='status']", text: "20% off for new customers of this store (Code WELCOME20)")
    expect(page).to have_selector("[role='status']", text: "We check previous purchases at checkout.")
    expect(page).not_to have_text("will be applied at checkout")
  end

  def refused_line
    find("[role='alert']", text: refusal).find(:xpath, "./ancestor::section[1]")
  end

  it "applies the discount for a signed-in buyer with no purchase history" do
    login_as create(:user)
    visit "#{product.long_url}/welcome20"

    expect_new_customer_offer
    expect(page).to have_selector("[itemprop='price']", text: "$30 $24", visible: false)
  end

  it "rejects the code for a signed-in buyer who has bought from the store before" do
    buyer = create(:user)
    other_product = create(:product, user: seller, price_cents: 5_00)
    create(:purchase, purchaser: buyer, link: other_product, seller:, price_cents: 0)

    login_as buyer
    visit "#{product.long_url}/welcome20"

    expect(page).to have_selector("[role='status']", text: "Sorry, this discount code is only for new customers.")
    expect_full_price
  end

  # Checkout decides on the email the visitor enters, so the page offers the code with its condition
  # instead of refusing someone it can't identify.
  it "offers the code to a visitor who is not signed in, conditional on being new to the store" do
    visit "#{product.long_url}/welcome20"

    expect_new_customer_offer
    expect(page).to have_selector("[itemprop='price']", text: "$30 $24", visible: false)
  end

  it "keeps the code's other conditions alongside the new-customer one" do
    offer_code.update!(minimum_quantity: 2, minimum_amount_cents: 5000)
    visit "#{product.long_url}/welcome20"

    expect(page).to have_selector("[role='status']", text: "Get 20% off when you buy 2 or more (Code WELCOME20)")
    expect(page).to have_selector("[role='status']", text: "This discount will apply when you spend $50 or more.")
    expect(page).to have_selector("[role='status']", text: "For new customers of this store. We check previous purchases at checkout.")
  end

  context "when a guest checks out" do
    let(:earlier_product) { create(:product, user: seller, price_cents: 2000, name: "Starter Pack") }
    let!(:free_code) do
      create(:offer_code, :for_new_customers, user: seller, products: [product], amount_cents: nil, amount_percentage: 100, code: "firstorder")
    end

    it "says who qualifies when the code is entered at checkout" do
      seller.update!(display_offer_code_field: true)
      visit product.long_url
      add_to_cart(product)
      fill_in "Discount code", with: "firstorder"
      click_on "Apply"

      expect(page).to have_selector("[aria-label='Discount code']", text: "firstorder")
      expect(page).to have_text("Total US$0", normalize_ws: true)
      expect(page).to have_text("FIRSTORDER is for new customers of this store. We check previous purchases when you pay.")
    end

    it "completes a first purchase from the store with the code" do
      visit "#{product.long_url}/firstorder"
      add_to_cart(product, offer_code: free_code)
      check_out(product, email: "first.time@example.com", is_free: true)

      expect(Purchase.last).to have_attributes(offer_code: free_code, price_cents: 0, email: "first.time@example.com")
      expect(page).not_to have_link("Back to checkout")
    end

    it "rejects an email that already bought from the store and takes the buyer back to their cart to remove the code" do
      create(:purchase, link: earlier_product, purchaser: nil, email: "Repeat.Buyer@Example.com")

      visit "#{product.long_url}/firstorder"
      add_to_cart(product, offer_code: free_code)
      check_out(product, email: "repeat.buyer@example.com", is_free: true, error: refusal)

      expect(page).to have_text("Go back to checkout to continue without this code.")
      within(refused_line) do
        expect(page).to have_text(product.name)
        expect(page).not_to have_selector(".receipt-price")
      end
      click_on "Back to checkout"

      expect(page).to have_current_path(checkout_path)
      expect(page).to have_text("Total US$0", normalize_ws: true)
      find("[aria-label='Discount code']", text: "firstorder").click
      expect(page).not_to have_selector("[aria-label='Discount code']", text: "firstorder")
      expect(page).to have_text("Total US$30", normalize_ws: true)

      check_out(product, email: "repeat.buyer@example.com")
      expect(product.sales.successful.last).to have_attributes(email: "repeat.buyer@example.com", price_cents: 3000, offer_code: nil)
    end

    context "when the seller's automatic sale is a legacy new-customers-only code" do
      let(:legacy_seller) { create(:user) }
      let(:course) { create(:product, user: legacy_seller, price_cents: 3000, name: "Pro Course") }
      let(:legacy_earlier_product) { create(:product, user: legacy_seller, price_cents: 2000, name: "Starter Pack") }

      before do
        # Validations refuse auto_apply on a new-customers-only code, so the legacy row is written directly.
        create(:universal_offer_code, user: legacy_seller, code: "WELCOME", amount_cents: nil, amount_percentage: 100, currency_type: nil, auto_apply: true)
          .update_columns(new_customers_only: true)
      end

      # A cart saved while the code was automatic stores it like a link code: only the code and fromUrl.
      def checkout_with_saved_legacy_code
        visit course.long_url
        within(find(:article)) { click_on "I want this!" }
        expect(page).to have_field("Email address")
        wait_until_true(sleep_interval: CheckoutPresenter::CART_SAVE_DEBOUNCE_DURATION_IN_SECONDS) { Cart.alive.where(user_id: nil).exists? }
        Cart.alive.where(user_id: nil).sole.update!(discount_codes: [{ code: "WELCOME", fromUrl: true }])
        visit checkout_path
        expect(page).to have_text("Total US$0", normalize_ws: true)
      end

      it "doesn't apply it to a visitor" do
        visit course.long_url

        expect(page).to have_selector("[itemprop='price']", exact_text: "$30", visible: false)
      end

      it "lets a returning guest remove it from a saved cart and pay" do
        create(:purchase, link: legacy_earlier_product, purchaser: nil, email: "repeat.buyer@example.com")
        checkout_with_saved_legacy_code

        check_out(course, email: "repeat.buyer@example.com", is_free: true, error: refusal)
        click_on "Back to checkout"
        find("[aria-label='Discount code']", text: "WELCOME").click
        expect(page).not_to have_selector("[aria-label='Discount code']", text: "WELCOME")
        expect(page).to have_text("Total US$30", normalize_ws: true)

        check_out(course, email: "repeat.buyer@example.com")
        expect(course.sales.successful.last).to have_attributes(email: "repeat.buyer@example.com", price_cents: 3000, offer_code: nil)
      end

      it "still gives a first-time guest the saved code" do
        checkout_with_saved_legacy_code

        check_out(course, email: "first.time@example.com", is_free: true)
        expect(course.sales.successful.last).to have_attributes(email: "first.time@example.com", price_cents: 0, offer_code: OfferCode.find_by!(code: "WELCOME"))
      end
    end

    it "explains the refusal without a way back when other items in the order went through" do
      create(:purchase, link: earlier_product, purchaser: nil, email: "repeat.buyer@example.com")
      free_guide = create(:product, user: seller, price_cents: 0, name: "Free Guide")

      visit free_guide.long_url
      add_to_cart(free_guide, pwyw_price: 0)
      visit "#{product.long_url}/firstorder"
      add_to_cart(product, offer_code: free_code)
      check_out(product, email: "repeat.buyer@example.com", is_free: true, error: refusal)

      expect(free_guide.sales.successful.last).to have_attributes(email: "repeat.buyer@example.com")
      expect(page).to have_text("Summary")
      within(refused_line) { expect(page).not_to have_selector(".receipt-price") }
      expect(page).not_to have_text("Go back to checkout")
      expect(page).not_to have_link("Back to checkout")
    end
  end
end
