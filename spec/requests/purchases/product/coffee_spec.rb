# frozen_string_literal: true

require "spec_helper"

describe "Coffee", type: :system, js: true do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:coffee) do
    create(
      :product,
      name: "Buy me a coffee!",
      description: "Please give me money. Pretty please! I really need it.",
      user: seller,
      native_type: Link::NATIVE_TYPE_COFFEE,
    )
  end

  context "one suggested amount" do
    it "shows the custom price input filled with that amount and allows purchase" do
      visit coffee.long_url

      expect(page).to have_selector("h1", text: "Buy me a coffee!")
      expect(page).to have_selector("h3", text: "Please give me money. Pretty please! I really need it.")

      expect(page).to_not have_radio_button

      expect(page).to have_field("Price", with: "1")

      click_on "Donate"
      expect(page).to have_current_path("/checkout")

      within_cart_item "Buy me a coffee!" do
        expect(page).to have_text("US$1")
        select_disclosure "Configure" do
          fill_in "Price", with: ""
          click_on "Save changes"
          expect(find_field("Price")["aria-invalid"]).to eq("true")
          fill_in "Price", with: "2"
          click_on "Save changes"
        end
        expect(page).to have_text("US$2")
      end

      fill_checkout_form(coffee)
      click_on "Pay"

      wait_for_ajax
      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")
      expect(current_url).to eq(custom_domain_coffee_url(host: coffee.user.subdomain_with_protocol))

      purchase = Purchase.last
      expect(purchase).to be_successful
      expect(purchase.price_cents).to eq(200)
      expect(purchase.link).to eq(coffee)
      expect(purchase.variant_attributes).to eq([])
    end

    it "rejects zero price" do
      visit coffee.long_url
      fill_in "Price", with: "0"

      click_on "Donate"
      expect(find_field("Price")["aria-invalid"]).to eq("true")
    end
  end

  context "multiple suggested amounts" do
    before do
      create(:variant, name: "", variant_category: coffee.variant_categories_alive.first, price_difference_cents: 200)
      create(:variant, name: "", variant_category: coffee.variant_categories_alive.first, price_difference_cents: 300)
      coffee.save_custom_button_text_option("tip_prompt")
    end

    it "shows radio buttons and allows purchase" do
      visit coffee.long_url

      expect(page).to have_radio_button("$1", checked: true)
      expect(page).to have_radio_button("$2", checked: false)
      expect(page).to have_radio_button("$3", checked: false)
      expect(page).to have_radio_button("Other", checked: false)
      expect(page).to_not have_field("Price")

      choose "$2"

      click_on "Tip"

      within_cart_item "Buy me a coffee!" do
        select_disclosure "Configure" do
          choose "$3"
          click_on "Save changes"
        end
      end

      fill_checkout_form(coffee)
      click_on "Pay"
      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = Purchase.last
      expect(purchase).to be_successful
      expect(purchase.price_cents).to eq(300)
      expect(purchase.link).to eq(coffee)
      expect(purchase.variant_attributes).to eq([coffee.alive_variants.third])
    end

    it "allows custom amount purchases" do
      visit coffee.long_url
      choose "Other"
      fill_in "Price", with: "100"

      click_on "Tip"
      fill_checkout_form(coffee)
      click_on "Pay"
      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com")

      purchase = Purchase.last
      expect(purchase).to be_successful
      expect(purchase.price_cents).to eq(10000)
      expect(purchase.link).to eq(coffee)
      expect(purchase.variant_attributes).to eq([])
    end
  end

  context "email formatting in body text" do
    let(:coffee_with_email) do
      create(
        :product,
        name: "Buy me a coffee!",
        description: "Contact me at test@example.com for questions.",
        user: seller,
        native_type: Link::NATIVE_TYPE_COFFEE,
      )
    end

    it "displays email addresses as clickable links" do
      visit coffee_with_email.long_url

      expect(page).to have_selector("h1", text: "Buy me a coffee!")
      expect(page).to have_link("test@example.com", href: "mailto:test@example.com")
      expect(page).not_to have_text('<a href="mailto:test@example.com"')
    end
  end
end
