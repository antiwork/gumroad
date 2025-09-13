# frozen_string_literal: true

describe("Product Page - Shipping Scenarios", type: :system, js: true, shipping: true) do
  it "shows the shipping in USD in the blurb and not apply taxes on top of it" do
    @user = create(:user_with_compliance_info)

    @product = create(
      :physical_product,
      user: @user,
      require_shipping: true,
      price_cents: 100_00,
      price_currency_type: "gbp"
    )
    @product.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 2000, multiple_items_rate_cents: 1000)
    @product.save!

    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    check_out(@product, address: { street: "3029 W Sherman Rd", city: "San Tan Valley", state: "AZ", zip_code: "85144" }, should_verify_address: true) do
      expect(page).to have_text("Subtotal US$153.24", normalize_ws: true)
      expect(page).to have_text("Sales tax US$10.27", normalize_ws: true)
      expect(page).to have_text("Shipping rate US$30.65", normalize_ws: true)
      expect(page).to have_text("Total US$194.16", normalize_ws: true)
    end

    expect(Purchase.last.price_cents).to eq(18389)
    expect(Purchase.last.shipping_cents).to eq(3065)
    expect(Purchase.last.gumroad_tax_cents).to eq(1027)
  end

  it "shows the blurb for a purchase in USD" do
    @user = create(:user_with_compliance_info)

    @product = create(:product, user: @user, require_shipping: true, price_cents: 100_00)

    @product.is_physical = true
    @product.price_currency_type = "usd"
    @product.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 2000, multiple_items_rate_cents: 1000)
    @product.save!

    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    check_out(@product, address: { street: "3029 W Sherman Rd", city: "San Tan Valley", state: "AZ", zip_code: "85144" }, should_verify_address: true) do
      expect(page).to have_text("Subtotal US$100", normalize_ws: true)
      expect(page).to have_text("Sales tax US$6.70", normalize_ws: true)
      expect(page).to have_text("Shipping rate US$20", normalize_ws: true)
      expect(page).to have_text("Total US$126.70", normalize_ws: true)
    end

    expect(Purchase.last.price_cents).to eq(12000)
    expect(Purchase.last.shipping_cents).to eq(2000)
    expect(Purchase.last.gumroad_tax_cents).to eq(670)
  end

  it "pre-selects user's country if not US, and shows appropriate shipping fee" do
    product = create(:product, require_shipping: true, is_physical: true, price_currency_type: "usd")
    product.shipping_destinations << build(:shipping_destination, country_code: "US", one_item_rate_cents: 10_00, multiple_items_rate_cents: 10_00)
    product.shipping_destinations << build(:shipping_destination, country_code: "IT", one_item_rate_cents: 15_00, multiple_items_rate_cents: 15_00)
    product.save!

    allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("72.229.28.185") # US

    visit "/l/#{product.unique_permalink}"
    add_to_cart(product)

    expect(page).to have_field("Country", with: "US")
    expect(page).to have_text("Shipping rate US$10", normalize_ws: true)

    allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("2.47.255.255") # Italy

    visit current_path

    expect(page).to have_field("Country", with: "IT")
    expect(page).to have_text("Shipping rate US$15", normalize_ws: true)
  end

  it "multiple quantities and an offer code" do
    @product = create(:physical_product, user: create(:user), require_shipping: true, price_cents: 100_00)
    @product.price_currency_type = "usd"
    @product.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 20_00, multiple_items_rate_cents: 15_00)
    @product.save!

    @offer_code = create(:offer_code, products: [@product], amount_cents: 50_00, user: @product.user)

    visit "/l/#{@product.unique_permalink}/#{@offer_code.code}"
    expect(page).to have_selector("[role='status']", text: "$50 off will be applied at checkout (Code #{@offer_code.code.upcase})")
    expect(page).to have_selector("[itemprop='price']", text: "$100 $50")
    add_to_cart(@product, quantity: 2, offer_code: @offer_code)
    check_out(@product, should_verify_address: true) do
      expect(page).to have_text("Shipping rate US$35", normalize_ws: true)
      expect(page).to have_text("Total US$135", normalize_ws: true)
    end

    expect(Purchase.last.price_cents).to eq(13500)
    expect(Purchase.last.shipping_cents).to eq(3500)
    expect(Purchase.last.quantity).to eq(2)
  end

  it "includes the default sku with the purchase" do
    @product = create(:physical_product, user: create(:user))

    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    check_out(@product, should_verify_address: true)

    expect(Purchase.last.variant_attributes).to eq(@product.skus.is_default_sku)
  end

  it "saves shipping address to purchaser if logged in" do
    # have to mock EasyPost calls because the timeout throws before EasyPost responds in testing
    easy_post = EasyPost::Client.new(api_key: GlobalConfig.get("EASYPOST_API_KEY"))
    address = easy_post.address.create(
      verify: ["delivery"],
      street1: "1640 17th St",
      city: "San Francisco",
      state: "CA",
      zip: "94107",
      country: "US"
    )
    expect_any_instance_of(EasyPost::Services::Address).to receive(:create).at_least(:once).and_return(address)

    link = create(:product, price_cents: 200, require_shipping: true)
    user = create(:user, credit_card: create(:credit_card))
    login_as(user)
    visit "#{link.user.subdomain_with_protocol}/l/#{link.unique_permalink}"

    add_to_cart(link)
    check_out(link, logged_in_user: user, credit_card: nil, should_verify_address: true)

    purchaser = Purchase.last.purchaser
    expect(purchaser.street_address).to eq("1640 17TH ST")
    expect(purchaser.city).to eq("SAN FRANCISCO")
    expect(purchaser.state).to eq("CA")
    expect(purchaser.zip_code).to eq("94107")
  end

  context "for a product with a single-unit currency" do
    it "calculates the correct shipping rate" do
      product = create(:physical_product, require_shipping: true, is_physical: true, price_currency_type: "jpy", price_cents: 500)
      product.shipping_destinations << build(:shipping_destination, country_code: "US", one_item_rate_cents: 500, multiple_items_rate_cents: 500)

      visit product.long_url
      add_to_cart(product)
      expect(page).to have_text("Subtotal US$6.38", normalize_ws: true)
      expect(page).to have_text("Shipping rate US$6.38", normalize_ws: true)
      expect(page).to have_text("Total US$12.76", normalize_ws: true)
      check_out(product, should_verify_address: true)

      expect(Purchase.last.price_cents).to eq(1276)
      expect(Purchase.last.shipping_cents).to eq(638)
    end
  end

  context "when the buyer's country is not in the seller's shipping destinations" do
    let(:product) { create(:product, require_shipping: true, is_physical: true, price_cents: 500) }
    let(:buyer) { create(:buyer_user, country: "Canada") }

    before do
      product.shipping_destinations << build(:shipping_destination, country_code: "US", one_item_rate_cents: 500)
    end

    it "allows purchase" do
      login_as buyer
      visit product.long_url
      add_to_cart(product)
      check_out(product, logged_in_user: buyer, should_verify_address: true)

      purchase = Purchase.last
      expect(purchase.country).to eq("United States")
      expect(purchase.price_cents).to eq(1000)
      expect(purchase.shipping_cents).to eq(500)
    end
  end
end
