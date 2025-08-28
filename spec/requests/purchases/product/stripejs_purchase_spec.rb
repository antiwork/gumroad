# frozen_string_literal: true

require("spec_helper")
require "timeout"

describe("PurchaseScenario using StripeJs", type: :system, js: true) do
  it "uses a users saved cc if they have one" do
    previous_successful_sales_count = Purchase.successful.count
    link = create(:product, price_cents: 200)
    user = create(:user)
    credit_card = create(:credit_card)
    credit_card.users << user
    login_as user
    visit "#{link.user.subdomain_with_protocol}/l/#{link.unique_permalink}"
    add_to_cart(link)
    check_out(link, logged_in_user: user)
    expect(Purchase.successful.count).to eq previous_successful_sales_count + 1
  end

  it("allows the buyer to pay with a new credit card") do
    link = create(:product_with_pdf_file, user: create(:user))

    visit("/l/#{link.unique_permalink}")

    expect(Stripe::PaymentMethod).to receive(:retrieve).and_call_original
    expect(Stripe::PaymentIntent).to receive(:create).and_call_original

    add_to_cart(link)
    check_out(link)

    new_purchase = Purchase.last
    expect(new_purchase.stripe_transaction_id).to match(/\Ach_/)
    expect(new_purchase.stripe_fingerprint).to_not be(nil)
    expect(new_purchase.card_type).to eq "visa"
    expect(new_purchase.card_country).to eq "US"
    expect(new_purchase.card_country_source).to eq Purchase::CardCountrySource::STRIPE
    expect(new_purchase.card_visual).to eq "**** **** **** 4242"
    expect(new_purchase.card_expiry_month).to eq StripePaymentMethodHelper::EXPIRY_MM.to_i
    expect(new_purchase.card_expiry_year).to eq StripePaymentMethodHelper::EXPIRY_YYYY.to_i
    expect(new_purchase.successful?).to be(true)
  end

  describe "save credit card payment" do
    before :each do
      @buyer = create(:user)
      login_as(@buyer)
      @product = create(:product)
    end

    it "saves when opted" do
      visit "#{@product.user.subdomain_with_protocol}/l/#{@product.unique_permalink}"

      add_to_cart(@product)

      expect(page).to have_checked_field("Save card")

      check_out(@product, logged_in_user: @buyer)

      purchase = Purchase.last
      expect(purchase.purchase_state).to eq("successful")
      expect(purchase.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
      expect(purchase.card_type).to eq "visa"
      expect(purchase.card_country).to eq "US"
      expect(purchase.card_country_source).to eq Purchase::CardCountrySource::STRIPE
      expect(purchase.card_visual).to eq "**** **** **** 4242"

      credit_card = @buyer.reload.credit_card
      expect(CreditCard.last).to eq(credit_card)
      expect(credit_card.card_type).to eq(CardType::VISA)
      expect(credit_card.visual).to eq("**** **** **** 4242")
    end

    it "does not save the card when opted out" do
      visit "#{@product.user.subdomain_with_protocol}/l/#{@product.unique_permalink}"
      add_to_cart(@product)
      expect(page).to have_checked_field("Save card")
      uncheck "Save card"
      check_out(@product, logged_in_user: @buyer)

      purchase = Purchase.last
      expect(purchase.card_type).to eq "visa"
      expect(purchase.card_country).to eq "US"
      expect(purchase.card_country_source).to eq Purchase::CardCountrySource::STRIPE
      expect(purchase.card_visual).to eq "**** **** **** 4242"

      expect(@buyer.reload.credit_card).to be(nil)
    end
  end

  describe "pay what you want" do
    before do
      @pwyw_product = create(:product)
    end

    describe "paid, untaxed purchase without shipping" do
      before do
        @pwyw_product.price_range = "30+"
        @pwyw_product.customizable_price = true
        @pwyw_product.save!
      end

      it "shows the payment blurb" do
        visit "/l/#{@pwyw_product.unique_permalink}"

        add_to_cart(@pwyw_product, pwyw_price: 35)

        expect(page).to have_text("Total US$35", normalize_ws: true)
      end
    end

    describe "multiple variants: 0+ and non-0+" do
      before do
        @pwyw_product.price_range = "0+"
        @pwyw_product.customizable_price = true
        @pwyw_product.save!

        @variant_category = create(:variant_category, link: @pwyw_product, title: "type")
        @var_zero_plus = create(:variant, variant_category: @variant_category, name: "Zero-plus", price_difference_cents: 0)
        @var_paid = create(:variant, variant_category: @variant_category, name: "Paid", price_difference_cents: 500)
      end

      it "lets to purchase the zero-plus variant for free" do
        visit "/l/#{@pwyw_product.unique_permalink}"

        add_to_cart(@pwyw_product, pwyw_price: 0, option: "Zero-plus")

        check_out(@pwyw_product, is_free: true)
      end

      it "does not let to purchase the paid variant for free, shows PWYW error instead of going to CC form" do
        visit "/l/#{@pwyw_product.unique_permalink}"

        choose "Paid"
        fill_in "Name a fair price", with: 0
        click_on "I want this!"
        expect(find_field("Name a fair price")["aria-invalid"]).to eq("true")
        expect(page).not_to have_button("Pay")

        fill_in "Name a fair price", with: 4
        click_on "I want this!"
        expect(find_field("Name a fair price")["aria-invalid"]).to eq("true")
        expect(page).not_to have_button("Pay")

        add_to_cart(@pwyw_product, pwyw_price: 6, option: "Paid")

        expect(page).to have_button("Pay")

        expect(page).to have_text("Total US$6", normalize_ws: true)

        check_out(@pwyw_product)

        purchase = Purchase.last
        expect(purchase.card_type).to eq "visa"
        expect(purchase.card_country).to eq "US"
        expect(purchase.card_country_source).to eq Purchase::CardCountrySource::STRIPE
        expect(purchase.card_visual).to eq "**** **** **** 4242"
        expect(purchase.price_cents).to eq(6_00)
      end
    end

    describe "free purchase" do
      before do
        @pwyw_product.price_range = "0+"
        @pwyw_product.customizable_price = true
        @pwyw_product.save!
      end

      it "does not show the payment blurb nor 'charged your card' message" do
        visit "/l/#{@pwyw_product.unique_permalink}"

        add_to_cart(@pwyw_product, pwyw_price: 0)

        check_out(@pwyw_product, is_free: true)
      end

      describe "processes an EU style formatted PWYW input" do
        it "parses and charges the right amount" do
          visit "/l/#{@pwyw_product.unique_permalink}"

          add_to_cart(@pwyw_product, pwyw_price: 1000.50)

          expect(page).to have_text("Total US$1,000.50", normalize_ws: true)

          check_out(@pwyw_product, is_free: false)

          purchase = Purchase.last
          expect(purchase.card_type).to eq "visa"
          expect(purchase.card_country).to eq "US"
          expect(purchase.card_country_source).to eq Purchase::CardCountrySource::STRIPE
          expect(purchase.card_visual).to eq "**** **** **** 4242"
          expect(purchase.price_cents).to eq(100050)
        end
      end
    end
  end
end
