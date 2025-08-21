# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/discover_layout"

describe("ProductShowScenario", type: :system, js: true) do
  it("sets the quantity and price based on the parameters in the query string and allows purchase") do
    product = create(:product, customizable_price: true, quantity_enabled: true)
    quantity = 3
    price_per_unit = 2.5
    total_price = quantity * price_per_unit

    visit short_link_path(product, quantity:, price: price_per_unit)
    expect(page).to have_field("Quantity", with: 3)
    expect(page).to have_field("Name a fair price", with: "2.50")

    add_to_cart(product, quantity: 3, pwyw_price: 2.5)
    check_out(product)

    expect(product.sales.successful.last.quantity).to eq(quantity)
    expect(product.sales.successful.last.price_cents).to eq(total_price * 100)
  end

  it "preselects and allows purchase of a physical product sku as specified in the variant query string parameter" do
    product = create(:product, is_physical: true, require_shipping: true, skus_enabled: true)
    product.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2,
                                                             one_item_rate_cents: 4_00,
                                                             multiple_items_rate_cents: 2_00)
    product.save!
    variant_category_1 = create(:variant_category, link: product)
    %w[Red Blue Green].each { |name| create(:variant, name:, variant_category: variant_category_1) }
    variant_category_2 = create(:variant_category, link: product)
    ["Small", "Medium", "Large", "Extra Large"].each { |name| create(:variant, name:, variant_category: variant_category_2) }
    variant_category_3 = create(:variant_category, link: product)
    %w[Polo Round].each { |name| create(:variant, name:, variant_category: variant_category_3) }
    Product::SkusUpdaterService.new(product:).perform

    visit short_link_path(product, option: product.skus.find_by(name: "Blue - Extra Large - Polo").external_id)
    expect(page).to have_radio_button("Blue - Extra Large - Polo")

    add_to_cart(product, option: "Blue - Extra Large - Polo")
    check_out(product)
  end

  it "preselects and allows purchase of a variant as specified in the variant query string parameter" do
    product = create(:product, customizable_price: true, price_cents: "200")

    variant_category_1 = create(:variant_category, link: product)
    %w[Red Blue Green].each_with_index { |name, index| create(:variant, name:, variant_category: variant_category_1, price_difference_cents: index * 100) }

    visit short_link_path(product, price: "8") + "&option=#{variant_category_1.variants.third.external_id}"
    expect(page).to have_radio_button("Green", checked: true)
    expect(page).to have_field("Name a fair price", with: "8")

    add_to_cart(product, option: "Green", pwyw_price: 8)
    check_out(product)
  end

  it "ensures correct price formatting" do
    product = create(:product, customizable_price: true)
    visit short_link_path(product)
    fill_in "Name a fair price", with: "-1234,.439"
    expect(page).to have_field "Name a fair price", with: "1234.43"
  end

  it "discards the quantity, price, and variant query string parameters if they are not applicable to the product" do
    product = create(:product)

    visit short_link_path(product, quantity: 3, price: 11) + "&option=fake"
    add_to_cart(product)
    check_out(product)

    expect(product.sales.successful.last.quantity).to eq(1)
    expect(product.sales.successful.last.price_cents).to eq(product.default_price_cents)
  end

  it "preselects the subscription recurrence as specified in the URL and allows purchase" do
    product = create(:subscription_product_with_versions, subscription_duration: :monthly)
    create(:price, link: product, recurrence: "quarterly", price_cents: 250)
    create(:price, link: product, recurrence: "yearly", price_cents: 800)

    visit short_link_path(product, recurrence: "yearly")
    add_to_cart(product, option: "Untitled 1")
    check_out(product)
  end

  it "fills the custom fields of the product based on query string parameters and allows purchase" do
    product = create(:product)
    product.custom_fields << [
      create(:custom_field, name: "First Name"),
      create(:custom_field, name: "Gender")
    ]
    product.save!

    visit short_link_path(product, "First Name" => "gumbot", "Gender" => "male")
    add_to_cart(product)

    expect(page).to have_field("First Name", with: "gumbot")
    expect(page).to have_field("Gender", with: "male")

    check_out(product)

    expect(product.sales.successful.last.custom_fields).to eq(
      [
        { name: "First Name", value: "gumbot", type: CustomField::TYPE_TEXT },
        { name: "Gender", value: "male", type: CustomField::TYPE_TEXT }
      ]
    )
  end

  it "shows remaining products count" do
    product = create(:product, max_purchase_count: 1)
    visit short_link_path(product)
    expect(page).to have_content "1 left"
  end

  context "membership product with free trial" do
    let(:product) { create(:membership_product, :with_free_trial_enabled) }

    it "displays information about a 1 week free trial" do
      visit short_link_path(product)
      expect(page).to have_content "All memberships include a 1 week free trial"
    end

    it "displays information about a 1 month free trial" do
      product.update!(free_trial_duration_unit: "month", free_trial_duration_amount: 1)
      visit short_link_path(product)
      expect(page).to have_content "All memberships include a 1 month free trial"
    end
  end

  it "records a page view for legacy URLs" do
    product = create(:product, custom_permalink: "custom")

    visit short_link_path(product)
    expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("index", hash_including("class_name" => "ProductPageView"))
  end

  it "records a page view for subdomain URLs" do
    product = create(:product, custom_permalink: "custom")

    visit product.long_url
    expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("index", hash_including("class_name" => "ProductPageView"))
  end

  context "when `?wanted=true`" do
    before do
      @product = create(:product, quantity_enabled: true)
      @membership = create(:membership_product_with_preset_tiered_pwyw_pricing)
      @membership.custom_fields = [create(:custom_field, name: "your nickname")]
      @membership.save!
      @offer_code = create(:offer_code, products: [@membership], amount_cents: 500)
    end

    it "opens the checkout page and sets the appropriate values" do
      visit "#{@membership.long_url}/#{@offer_code.code}?wanted=true&recurrence=biannually&option=#{@membership.variant_categories.first.variants.second.external_id}&email=gumhead@gumroad.com&your nickname=moneybags"
      within "[role='listitem']" do
        expect(page).to have_text(@membership.name)
        expect(page).to have_text("Tier: Second Tier")
        expect(page).to have_text("Membership: Every 6 months")
      end
      expect(page).to have_field("Email address", with: "gumhead@gumroad.com")
      expect(page).to have_field("your nickname", with: "moneybags")
      expect(page).to have_selector("[aria-label='Discount code']", text:  @offer_code.code)
      click_on "Remove"

      visit "#{@product.long_url}?wanted=true&quantity=3"

      within "[role='listitem']" do
        expect(page).to have_text(@membership.name)
        expect(page).to have_text("Qty: 3")
      end
    end

    context "with a product with an installment plan" do
      let!(:product) { create(:product, price_cents: 10000) }
      let!(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 3) }

      it "passes the pay_in_installments parameter to the checkout page" do
        visit "#{product.long_url}?wanted=true&pay_in_installments=true"

        within_cart_item product.name do
          expect(page).to have_text("in 3 installments")
        end
      end
    end

    context "with a PWYW product" do
      before do
        @pwyw_product = create(:product, customizable_price: true, price_cents: 99)
      end

      it "opens the checkout page when the price parameter is valid" do
        visit "#{@pwyw_product.long_url}?wanted=true&price=99"
        within "[role='listitem']" do
          expect(page).to have_text(@membership.name)
          expect(page).to have_text("$99")
        end
      end

      it "opens the product page when the price parameter is not set" do
        visit "#{@pwyw_product.long_url}?wanted=true"
        expect(page).to_not have_text("Checkout")
      end

      it "opens the product page when the price parameter is invalid" do
        visit "#{@pwyw_product.long_url}?wanted=true&price=0.98"
        expect(page).to_not have_text("Checkout")
      end

      it "displays a decimal price input" do
        visit @pwyw_product.long_url
        expect(find_field("Name a fair price")["inputmode"]).to eq("decimal")
      end
    end
  end

  it "substitutes `<br>`s for newlines in variant descriptions" do
    @product = create(:product)
    @variant_category = create(:variant_category, link: @product)
    @variant = create(:variant, variant_category: @variant_category, description: "Description\nwith\nnewlines")

    visit @product.long_url
    expect(find(:radio_button, @variant.name)[:innerHTML]).to include("Description<br>with<br>newlines")
  end

  describe "Twitter meta tags" do
    before do
      @product = create(:product_with_pdf_file, preview_url: "https://staging-public-files.gumroad.com/happy_face.jpeg")
    end

    it "has the correct twitter meta tags on the product page" do
      visit("/l/#{@product.unique_permalink}")
      twitter_properties = {
        site: "@gumroad",
        image: @product.preview_url,
        card: "summary_large_image",
        title: CGI.escapeHTML(@product.name),
        description: @product.description
      }
      twitter_properties.each_pair do |property, value|
        expect(page.find("meta[property='twitter:#{property}']", visible: false).value).to eq value
      end
    end
  end

  describe "Product edit button" do
    let(:seller) { create(:named_user) }
    let(:product) { create(:product, user: seller) }

    shared_examples_for "with product edit button" do
      it "shows the product edit button" do
        visit short_link_url(product.unique_permalink, host: product.user.subdomain_with_protocol)
        expect(page).to have_link("Edit product", href: edit_link_url(product, host: DOMAIN))
      end
    end

    shared_examples_for "without product edit button" do
      it "doesn't show the product edit button" do
        visit short_link_url(product.unique_permalink, host: product.user.subdomain_with_protocol)
        expect(page).not_to have_link("Edit product", href: edit_link_url(product, host: DOMAIN))
      end
    end

    context "with seller as logged_in_user" do
      before do
        login_as(seller)
      end

      it_behaves_like "with product edit button"

      context "with switching account to user as admin for seller" do
        include_context "with switching account to user as admin for seller"

        it_behaves_like "with product edit button"
      end
    end

    context "with switching account to user as admin for seller" do
      include_context "with switching account to user as admin for seller"

      context "when accessing logged-in user's product" do
        let(:product) { create(:product, user: user_with_role_for_seller) }

        it_behaves_like "without product edit button"
      end
    end

    context "without user logged in" do
      it_behaves_like "without product edit button"
    end
  end

  context "when the product is a multi-seat license membership" do
    let(:product) { create(:membership_product, is_multiseat_license: true) }

    it "populates the seats field from the `quantity` query parameter" do
      visit "#{product.long_url}?quantity=4"
      expect(page).to have_field("Seats", with: "4")
    end
  end

  describe "Refund policy" do
    let(:product_refund_policy) do
      create(
        :product_refund_policy,
        max_refund_period_in_days: 7,
        fine_print: "Seriously, just email us and we'll refund you.",
      )
    end
    let(:product) { product_refund_policy.product }
    let(:seller) { product.user }

    before do
      seller.update!(refund_policy_enabled: false)
      product.update!(product_refund_policy_enabled: true)
    end

    it "renders product-level refund policy" do
      travel_to(Time.utc(2023, 4, 17)) do
        product_refund_policy.update!(updated_at: Time.current)
        visit product.long_url

        click_on("7-day money back guarantee")
        within_modal "7-day money back guarantee" do
          expect(page).to have_text("Seriously, just email us and we'll refund you.")
          expect(page).to have_text("Last updated Apr 17, 2023")
        end
      end
    end

    context "when the account-level refund policy is enabled" do
      before do
        seller.update!(refund_policy_enabled: true)
      end

      it "renders account-level refund policy" do
        travel_to(Time.utc(2023, 4, 17)) do
          seller.refund_policy.update!(fine_print: "This is an account-level refund policy fine print")
          visit product.long_url

          click_on("30-day money back guarantee")
          within_modal "30-day money back guarantee" do
            expect(page).to have_text("This is an account-level refund policy fine print")
            expect(page).to have_text("Last updated Apr 17, 2023")
          end
        end
      end

      context "when the URL contains refund-policy anchor" do
        it "renders with the modal open and creates event" do
          seller.refund_policy.update!(fine_print: "This is an account-level refund policy fine print")
          expect do
            visit "#{product.long_url}#refund-policy"
          end.to change { Event.count }.by(1)

          within_modal "30-day money back guarantee" do
            expect(page).to have_text("This is an account-level refund policy fine print")
          end

          event = Event.last
          expect(event.event_name).to eq(Event::NAME_PRODUCT_REFUND_POLICY_FINE_PRINT_VIEW)
          expect(event.link_id).to eq(product.id)
        end
      end
    end

    context "when the URL contains refund-policy anchor" do
      it "renders with the modal open and creates event" do
        expect do
          visit "#{product.long_url}#refund-policy"
        end.to change { Event.count }.by(1)

        within_modal "7-day money back guarantee" do
          expect(page).to have_text("Seriously, just email us and we'll refund you.")
        end

        event = Event.last
        expect(event.event_name).to eq(Event::NAME_PRODUCT_REFUND_POLICY_FINE_PRINT_VIEW)
        expect(event.link_id).to eq(product.id)
      end
    end
  end

  describe "Discount expiration countdown" do
    let(:product) { create(:product) }
    let(:offer_code) { create(:offer_code, products: [product], valid_at: 1.day.ago, expires_at: 15.seconds.from_now) }

    it "renders the countdown and switches to an error status upon expiration" do
      visit "#{product.long_url}/#{offer_code.code}"
      expect(page).to have_selector("[role='status']", text: /This discount expires in 00:\d{2}/)
      expect(page).to have_selector("[role='status']", text: "Sorry, the discount code you wish to use is inactive.")
    end
  end

  describe "Minimum quantity discount" do
    let(:product) { create(:product, quantity_enabled: true) }
    let(:offer_code) { create(:offer_code, products: [product], minimum_quantity: 2) }

    it "renders the minimum quantity discount notice and displays the discounted price when the minimum quantity is met" do
      visit "#{product.long_url}/#{offer_code.code}"

      expect(page).to have_selector("[role='status']", text: "Get $1 off when you buy 2 or more (Code SXSW)")
      expect(page).to have_selector("[itemprop='price']", exact_text: "$1")

      fill_in "Quantity", with: 2
      expect(page).to have_selector("[itemprop='price']", exact_text: "$1 $0")
      fill_in "Quantity", with: 1
      expect(page).to have_selector("[itemprop='price']", exact_text: "$1")
    end
  end

  context "when the CTA bar is visible" do
    let(:product) { create(:product) }

    before do
      asset_preview = create(:asset_preview, link: product)
      asset_preview.file.attach Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "error_file.jpeg"), "image/jpeg")
      asset_preview.file.analyze
    end

    context "when the product is PWYW" do
      before do
        product.update(customizable_price: true)
      end

      it "focuses the PWYW button when the CTA button in the CTA bar is clicked" do
        visit product.long_url
        within "[aria-label='Product information bar']" do
          click_on "I want this!"
        end
        expect(page).to have_field("Name a fair price:", focused: true)
        expect(page).to have_alert(text: "You must input an amount")
      end
    end

    context "when the product only has one variant" do
      let(:variant_category) { create(:variant_category, link: product) }
      let!(:variant) { create(:variant, variant_category:) }

      it "navigates to the checkout page when the CTA button in the CTA bar is clicked" do
        visit product.long_url
        within "[aria-label='Product information bar']" do
          click_on "I want this!"
        end
        expect(page.current_path).to eq("/checkout")
      end
    end
  end

  context "the product has a collaborator" do
    let(:product) { create(:product, is_collab: true) }
    let!(:collaborator) { create(:collaborator, seller: product.user) }
    let!(:product_affiliate) { create(:product_affiliate, affiliate: collaborator, product:, dont_show_as_co_creator: false) }

    context "dont_show_as_co_creator is false" do
      it "shows the collaborator as a co-creator" do
        visit product.long_url
        expect(page).to have_text("#{product.user.username} with #{collaborator.affiliate_user.username}", normalize_ws: true)
        expect(page).to have_link(product.user.username, href: root_url(host: product.user.subdomain_with_protocol))
        expect(page).to have_link(collaborator.affiliate_user.username, href: collaborator.affiliate_user.profile_url)
      end
    end

    context "dont_show_as_co_creator is true" do
      before { collaborator.update!(dont_show_as_co_creator: true) }

      it "doesn't show the collaborator as a co-creator" do
        visit product.long_url
        expect(page).to_not have_text("#{product.user.username} with #{collaborator.affiliate_user.username}")
      end
    end
  end

  describe "PWYW product" do
    context "without a discount" do
      context "regular product" do
        let(:product) { create(:product, price_cents: 1000, customizable_price: true, suggested_price_cents: 3000) }

        it "sets the PWYW input placeholder value correctly" do
          visit product.long_url
          expect(page).to have_field("Name a fair price:", with: "", placeholder: "30+")
        end

        it "rounds non-zero prices up to the currency minimum" do
          visit product.long_url
          pwyw_field = find_field("Name a fair price")
          pwyw_field.fill_in with: "0.1"
          find(:label, "Name a fair price:").click
          expect(pwyw_field["aria-invalid"]).to eq("true")
          expect(pwyw_field.value).to eq("0.99")
        end

        context "product is free" do
          before { product.update!(price_cents: 0) }

          it "rounds non-zero prices up to the currency minimum" do
            visit product.long_url
            pwyw_field = find_field("Name a fair price")
            pwyw_field.fill_in with: "0.1"
            find(:label, "Name a fair price:").click
            expect(pwyw_field["aria-invalid"]).to eq("false")
            expect(pwyw_field.value).to eq("0.99")

            add_to_cart(product, pwyw_price: 0.99)

            within "[role='listitem']" do
              select_disclosure "Configure" do
                fill_in "Name a fair price", with: "0.1"
                click_on "Save"
              end
              expect(page).to have_text("$0.99")
              select_disclosure "Configure" do
                fill_in "Name a fair price", with: "0"
                click_on "Save"
              end
              expect(page).to have_text("$0")
            end
          end
        end
      end

      context "versioned product" do
        let(:product) { create(:product_with_digital_versions, customizable_price: true, price_cents: 0, suggested_price_cents: 0) }

        before do
          product.alive_variants.each_with_index { _1.update(price_difference_cents: (_2 + 1) * 100) }
        end

        it "sets the PWYW input placeholder value correctly" do
          visit product.long_url
          expect(page).to have_field("Name a fair price:", with: "", placeholder: "1+")
          choose "Untitled 2"
          expect(page).to have_field("Name a fair price:", with: "", placeholder: "2+")
        end
      end

      context "membership product" do
        let(:product) { create(:membership_product_with_preset_tiered_pwyw_pricing) }

        it "sets the PWYW input placeholder value correctly" do
          visit product.long_url
          expect(page).to have_field("Name a fair price:", with: "", placeholder: "600+")
        end
      end
    end

    context "with a discount" do
      let(:seller) { create(:user) }
      let(:offer_code) { create(:offer_code, user: seller, universal: true, amount_cents: 100) }

      context "regular product" do
        let(:product) { create(:product, user: seller, price_cents: 1000, customizable_price: true) }

        it "sets the PWYW input placeholder value correctly" do
          visit "#{product.long_url}/#{offer_code.code}"
          expect(page).to have_field("Name a fair price:", with: "", placeholder: "9+")
        end
      end

      context "versioned product" do
        let(:product) { create(:product_with_digital_versions, user: seller, customizable_price: true, price_cents: 300) }

        it "sets the PWYW input placeholder value correctly" do
          visit "#{product.long_url}/#{offer_code.code}"
          expect(page).to have_field("Name a fair price:", with: "", placeholder: "2+")
        end
      end

      context "membership product" do
        let(:product) { create(:membership_product_with_preset_tiered_pwyw_pricing, user: seller) }

        before do
          product.alive_variants.each do |tier|
            tier.prices.each do |price|
              price.update!(suggested_price_cents: nil)
            end
          end
        end

        it "sets the PWYW input placeholder value correctly" do
          visit "#{product.long_url}/#{offer_code.code}"
          expect(page).to have_field("Name a fair price:", with: "", placeholder: "499+")
        end
      end
    end
  end

  it "includes a share menu with social links and copy functionality" do
    product = create(:product)
    visit product.long_url
    select_disclosure "Share" do
      expect(page).to have_link("Share on X")
      expect(page).to have_link("Share on Facebook")
      copy_button = find_button("Copy link")
      copy_button.hover
      expect(copy_button).to have_tooltip(text: "Copy product URL")
      copy_button.click
      expect(copy_button).to have_tooltip(text: "Copied")
    end
  end

  describe "discover layout" do
    let(:product) { create(:product, :recommendable, taxonomy: Taxonomy.find_by(slug: "design")) }

    let(:discover_url) { product.long_url(layout: Product::Layout::DISCOVER) }
    let(:non_discover_url) { product.long_url }

    it_behaves_like "discover navigation when layout is discover", selected_taxonomy: "Design"
  end

  context "sold out variants" do
    let!(:creator) { create(:named_user) }
    let!(:product) { create(:product, user: creator, name: "Test Product with Variants", hide_sold_out_variants: false) }
    let!(:variant_category) { create(:variant_category, link: product) }
    let!(:available_variant) { create(:variant, name: "Standard", variant_category: variant_category) }
    let!(:sold_out_variant) { create(:variant, name: "Starter", variant_category: variant_category, max_purchase_count: 1) }
    let!(:sold_out_variant_purchase) { create(:purchase, link: product, variant_attributes: [sold_out_variant]) }

    it "disables or hides the variant based on the hide_sold_out_variants setting" do
      # The sold out variant should be visible, but in a disabled state.
      product.update!(hide_sold_out_variants: false)

      visit product.long_url
      expect(page).to have_radio_button(sold_out_variant.name, disabled: true)
      expect(page).to have_radio_button(available_variant.name, disabled: false)

      # The sold out variant should not be visible on the page.
      product.update!(hide_sold_out_variants: true)

      visit product.long_url
      expect(page).not_to have_radio_button(sold_out_variant.name)
      expect(page).to have_radio_button(available_variant.name, disabled: false)
    end
  end
end
