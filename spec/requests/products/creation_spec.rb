# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Product creation", type: :system, js: true do
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

  context "user can create multiple products in one session" do
    it "creates multiple products" do
      visit new_product_path
      fill_in("Name", with: "My First product")
      choose("Digital product")
      fill_in("Price", with: 1)
      click_on("Next: Customize")

      expect(page).to have_title("My First product")
      expect(page).to have_text("Add details")
      product = seller.links.last
      expect(product.name).to eq("My First product")

      page.go_back

      fill_in("Name", with: "My Second product")
      choose("Digital product")
      fill_in("Price", with: 1)
      click_on("Next: Customize")

      expect(page).to have_title("My Second product")
      expect(page).to have_text("Add details")
      product = seller.links.last
      expect(product.name).to eq("My Second product")

      # Verify both products appear on the products list
      visit products_path
      expect(page).to have_content("My First product")
      expect(page).to have_content("My Second product")
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

  describe "AI Product Generation" do
    before do
      Feature.activate_user(:ai_product_generation, seller)
      allow_any_instance_of(User).to receive(:eligible_for_ai_product_generation?).and_return(true)
    end

    it "creates a product using AI prompt and customizes it" do
      vcr_turned_on do
        VCR.use_cassette("Product creation using AI") do
          visit new_product_path

          expect(page).to have_status(text: "New. You can create your product using AI now")

          click_on "Create a product with AI"

          fill_in "Create a product with AI", with: "Create a Ruby on Rails coding tutorial ebook with 4 chapters for $29.99"

          click_on "Generate"
          wait_for_ajax

          expect(page).to have_alert(text: "All set! Review the form below and hit 'Next: customize' to continue.")

          expect(page).to have_field("Name", with: "Ruby on Rails Coding Tutorial")
          expect(page).to have_radio_button("E-book", checked: true)
          expect(page).to have_field("Price", with: "29.99")

          click_on "Next: Customize"
          wait_for_ajax

          expect(page).to have_title("Ruby on Rails Coding Tutorial")
          expect(page).to have_status(text: "Your AI product is ready! Take a moment to check out the product and content tabs. Tweak things and make it your own—this is your time to shine!")
          within find("[aria-label='Description']") do
            expect(page).to have_text("Welcome to the Ruby on Rails Coding Tutorial ebook! This comprehensive guide is designed for both beginners and experienced developers who want to master the Ruby on Rails framework.")
          end

          product = seller.products.last
          within_section "Cover", section_element: :section do
            expect(page).to have_image(src: product.display_asset_previews.sole.url)
          end
          within_section "Thumbnail", section_element: :section do
            expect(page).to have_image("Thumbnail image", src: product.thumbnail.url)
          end
          within_fieldset "Additional details" do
            inputs = all("input[type='text']")
            expect(inputs[0].value).to eq("Pages")
            expect(inputs[1].value).to eq("4")
          end
          within_section "Pricing", section_element: :section do
            expect(page).to have_field("Amount", with: "29.99")
          end
          select_tab "Content"
          expect(page).to have_text("Chapter 1: Introduction to Ruby on Rails")
          expect(page).to have_text("Chapter 2: Setting Up Your Development Environment")
          expect(page).to have_text("Chapter 3: Building Your First Rails Application")
          expect(page).to have_text("Chapter 4: Advanced Features and Best Practices")
          within find("[aria-label='Content editor']") do
            expect(page).to have_text("What is Ruby on Rails?")
            expect(page).to have_text("Key Features of Ruby on Rails")
            expect(page).to have_text("In this chapter, we will delve deeper into the history of Ruby on Rails and its community.")
          end
        end
      end
    end
  end
end
