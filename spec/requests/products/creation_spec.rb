# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Product creation", type: :feature, js: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:user_with_admin_role) { create(:user, name: "Admin") }

  include_context "with switching account to user as admin for seller"



  describe "native types" do
    it "selects 'digital' by default" do
      visit new_product_path
      fill_in("Name", with: "Default digital native type")
      fill_in("Price", with: 1)
      click_on("Next: Customize")

      expect(page).to have_title("Default digital native type")
      expect(page).to have_text("Add details")
      expect(seller.products.last.native_type).to eq(Link::NATIVE_TYPE_DIGITAL)
    end

    it "creates a digital product" do
      visit new_product_path
      fill_in("Name", with: "Digital product native type")
      choose("Digital product")
      fill_in("Price", with: 1)
      click_on("Next: Customize")

      expect(page).to have_title("Digital product native type")
      expect(page).to have_text("Add details")
      product = seller.links.last
      expect(product.native_type).to eq("digital")
      expect(product.is_physical).to be(false)
      expect(product.is_recurring_billing).to be(false)
      expect(product.is_in_preorder_state).to be(false)
      expect(product.subscription_duration).to be_nil
      expect(product.custom_attributes).to eq([])
      expect(product.should_include_last_post).to be_falsey
    end

    it "creates a course product" do
      visit new_product_path
      fill_in("Name", with: "Course product native type")
      choose("Course or tutorial")
      fill_in("Price", with: 1)
      click_on("Next: Customize")

      expect(page).to have_title("Course product native type")
      expect(page).to have_text("Add details")
      product = seller.links.last
      expect(product.native_type).to eq("course")
      expect(product.is_physical).to be(false)
      expect(product.is_recurring_billing).to be(false)
      expect(product.is_in_preorder_state).to be(false)
      expect(product.subscription_duration).to be_nil
      expect(product.custom_attributes).to eq([])
      expect(product.should_include_last_post).to be_falsey
    end

    it "creates a ebook product" do
      visit new_product_path
      fill_in("Name", with: "Ebook product native type")
      choose("E-book")
      fill_in("Price", with: 1)
      click_on("Next: Customize")

      expect(page).to have_title("Ebook product native type")
      expect(page).to have_selector("input[value='Pages']")

      product = seller.links.last
      expect(product.native_type).to eq("ebook")
      expect(product.is_physical).to be(false)
      expect(product.is_recurring_billing).to be(false)
      expect(product.is_in_preorder_state).to be(false)
      expect(product.subscription_duration).to be_nil
      expect(product.custom_attributes).to eq([{ "name" => "Pages", "value" => "" }])
      expect(product.should_include_last_post).to be_falsey
    end

    it "creates a membership product" do
      visit new_product_path
      fill_in("Name", with: "membership product native type")
      choose("Membership")
      expect(page).to have_content("a month")
      select("every 6 months", from: "Default subscription duration", visible: false)
      fill_in("Price", with: 1)
      click_on("Next: Customize")

      expect(page).to have_title("membership product native type")
      expect(page).to have_text("Add details")
      expect(page).to have_checked_field("New members will be emailed this product's last published post")
      expect(page).to have_checked_field("New members will get access to all posts you have published")
      product = seller.links.last
      expect(product.native_type).to eq("membership")
      expect(product.is_physical).to be(false)
      expect(product.is_recurring_billing).to be(true)
      expect(product.is_in_preorder_state).to be(false)
      expect(product.subscription_duration).to eq("biannually")
      expect(product.custom_attributes).to eq([])
      expect(product.should_include_last_post).to be_truthy
    end

    context "physical products are disabled" do
      it "does not allow the creation of a physical product" do
        visit new_product_path
        expect(page).to_not have_radio_button("Physical good")
      end
    end

    context "physical products are enabled" do
      before { seller.update!(can_create_physical_products: true) }

      it "creates an physical product" do
        visit new_product_path
        fill_in("Name", with: "physical product native type")
        choose("Physical good")
        fill_in("Price", with: 1)
        click_on("Next: Customize")

        expect(page).to have_title("physical product native type")
        product = seller.links.last
        expect(product.native_type).to eq("physical")
        expect(product.is_physical).to be(true)
        expect(product.is_recurring_billing).to be(false)
        expect(product.is_in_preorder_state).to be(false)
        expect(product.subscription_duration).to be_nil
        expect(product.should_include_last_post).to be_falsey
      end
    end

    context "commissions are disabled" do
      it "does not allow the creation of a commission product" do
        visit new_product_path
        expect(page).to_not have_radio_button("Commission")
      end
    end

    context "commissions are enabled" do
      before { Feature.activate(:commissions) }

      context "seller is not eligible for service products" do
        it "does not allow the creation of a service product" do
          visit new_product_path
          commission_button = find(:radio_button, "Commission", disabled: true)
          commission_button.hover
          expect(commission_button).to have_tooltip(text: "Service products are disabled until your account is 30 days old.")
        end
      end

      context "seller is eligible for service products" do
        let(:seller) { create(:user, :eligible_for_service_products) }

        it "creates a commission product" do
          visit new_product_path
          choose "Commission"
          fill_in "Name", with: "My commission"
          fill_in "Price", with: "2"
          click_on "Next: Customize"

          expect(page).to have_title("My commission")
          product = seller.products.last
          expect(product.native_type).to eq("commission")
          expect(product.is_physical).to be(false)
          expect(product.is_recurring_billing).to be(false)
          expect(product.is_in_preorder_state).to be(false)
          expect(product.subscription_duration).to be_nil
          expect(product.custom_attributes).to eq([])
          expect(product.should_include_last_post).to be_falsey
        end
      end
    end
  end

  context "seller is not eligible for service products" do
    it "does not allow the creation of a coffee product" do
      visit new_product_path
      coffee_button = find(:radio_button, "Coffee", disabled: true)
      coffee_button.hover
      expect(coffee_button).to have_tooltip(text: "Service products are disabled until your account is 30 days old.")
    end

    it "does not allow the creation of a service product" do
      visit new_product_path
      call_button = find(:radio_button, "Call", disabled: true)
      call_button.hover
      expect(call_button).to have_tooltip(text: "Service products are disabled until your account is 30 days old.")
    end
  end

  context "seller is eligible for service products" do
    let(:seller) { create(:user, :eligible_for_service_products) }
    before do
      Feature.activate(:product_edit_react)
    end

    it "creates a coffee product" do
      visit new_product_path
      choose "Coffee"
      fill_in "Name", with: "My coffee"
      fill_in "Suggested amount", with: "1"
      click_on "Next: Customize"

      expect(page).to have_title("My coffee")
      product = seller.products.last
      expect(product.native_type).to eq("coffee")
      expect(product.is_physical).to be(false)
      expect(product.is_recurring_billing).to be(false)
      expect(product.is_in_preorder_state).to be(false)
      expect(product.subscription_duration).to be_nil
      expect(product.custom_attributes).to eq([])
      expect(product.should_include_last_post).to be_falsey
    end

    it "creates a call product" do
      visit new_product_path
      choose "Call"
      fill_in "Name", with: "My call"
      fill_in "Price", with: "1"
      click_on "Next: Customize"

      expect(page).to have_title("My call")
      product = seller.products.last
      expect(product.native_type).to eq("call")
      expect(product.is_physical).to be(false)
      expect(product.is_recurring_billing).to be(false)
      expect(product.is_in_preorder_state).to be(false)
      expect(product.subscription_duration).to be_nil
      expect(product.custom_attributes).to eq([])
      expect(product.should_include_last_post).to be_falsey
    end
  end

  describe "currencies" do
    it "creates a membership priced in a single-unit currency" do
      visit new_product_path
      fill_in("Name", with: "membership in yen")
      choose("Membership")
      select("¥ (Yen)", from: "Currency", visible: false)
      fill_in("Price", with: 5000)
      click_on("Next: Customize")

      expect(page).to have_title("membership in yen")
      product = seller.links.last
      tier_price = product.default_tier.prices.alive.first
      expect(product.price_currency_type).to eq("jpy")
      expect(tier_price.currency).to eq("jpy")
      expect(tier_price.price_cents).to eq(5000)
    end

    it "creates a digital product priced in a single-unit currency" do
      visit new_product_path
      fill_in("Name", with: "Digital product in yen")
      choose("Digital product")
      select("¥ (Yen)", from: "Currency", visible: false)
      fill_in("Price", with: 5000)
      click_on("Next: Customize")

      expect(page).to have_title("Digital product in yen")
      product = seller.links.last
      price = product.prices.alive.first
      expect(product.price_currency_type).to eq("jpy")
      expect(product.price_cents).to eq(5000)
      expect(price.currency).to eq("jpy")
      expect(price.price_cents).to eq(5000)
    end
  end

  describe "form validations" do
    it "focuses on name field on submit if name is not filled" do
      visit new_product_path
      fill_in("Price", with: 1)
      click_on("Next: Customize")

      name_field = find_field("Name")
      expect(page.active_element).to eq(name_field)
      expect(name_field.ancestor("fieldset.danger")).to be_truthy
    end

    it "focuses on price field on submit if price is not filled" do
      visit new_product_path
      fill_in("Name", with: "Digital product")
      choose("Digital product")
      click_on("Next: Customize")

      price_field = find_field("Price")
      expect(page.active_element).to eq(price_field)
      expect(price_field.ancestor("fieldset.danger")).to be_truthy
    end
  end

  describe "bundles" do
    it "allows the creation of a bundle" do
      visit new_product_path
      choose "Bundle"
      fill_in("Name", with: "Bundle")
      fill_in("Price", with: 1)
      click_on("Next: Customize")
      expect(page).to have_title("Bundle")

      product = Link.last
      expect(product.is_bundle).to eq(true)
      expect(product.native_type).to eq("bundle")
    end
  end

  it "does not automatically enable the community chat on creating a product" do
    Feature.activate_user(:communities, seller)
    visit new_product_path
    choose "Digital product"
    fill_in "Name", with: "My product"
    fill_in "Price", with: 1
    click_on "Next: Customize"
    wait_for_ajax
    expect(page).not_to have_checked_field("Invite your customers to your Gumroad community chat")
    product = seller.products.last
    expect(product.community_chat_enabled?).to be(false)
    expect(product.active_community).to be_nil
  end
end
