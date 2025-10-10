# frozen_string_literal: true

describe("Product Page - Shipping physical preoder", type: :system, js: true, shipping: true) do
  before do
    @creator = create(:user_with_compliance_info)
    @product = create(:physical_product, user: @creator, name: "physical preorder", price_cents: 16_00, require_shipping: true, is_in_preorder_state: true)
    @product.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 4_00, multiple_items_rate_cents: 1_00)
    @product.save!
    @preorder_link = create(:preorder_link, link: @product)
  end

  it "charges the proper amount and stores shipping without taxes" do
    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    check_out(@product, should_verify_address: true) do
      expect(page).to have_text("Shipping rate US$4", normalize_ws: true)
      expect(page).to have_text("Total US$20", normalize_ws: true)
    end

    expect(page.all(:css, ".receipt-price")[0].text).to eq("$16")

    expect(page.all(:css, ".product-name")[1].text).to eq("Shipping")
    expect(page.all(:css, ".receipt-price")[1].text).to eq("$4")

    purchase = Purchase.last
    preorder = Preorder.last

    expect(purchase.total_transaction_cents).to eq(20_00)
    expect(purchase.price_cents).to eq(20_00)
    expect(purchase.shipping_cents).to eq(4_00)
    expect(purchase.purchase_state).to eq("preorder_authorization_successful")
    expect(purchase.email).to eq("test@gumroad.com")
    expect(purchase.link).to eq(@product)
    expect(purchase.street_address.downcase).to eq("1640 17th st")
    expect(purchase.city.downcase).to eq("san francisco")
    expect(purchase.state).to eq("CA")
    expect(purchase.zip_code).to eq("94107")

    expect(preorder.preorder_link).to eq(@preorder_link)
    expect(preorder.seller).to eq(@creator)
    expect(preorder.state).to eq("authorization_successful")
  end

  it "allows a free preorder purchase" do
    @product.shipping_destinations.last.update!(one_item_rate_cents: 0, multiple_items_rate_cents: 0)
    offer_code = create(:offer_code, products: [@product], amount_cents: 16_00)

    visit "/l/#{@product.unique_permalink}/#{offer_code.code}"
    add_to_cart(@product, offer_code:)
    check_out(@product, is_free: true, should_verify_address: true)

    expect(page).to have_text("Your purchase was successful!")
    expect(page).to have_text("physical preorder $0", normalize_ws: true)

    purchase = Purchase.last
    preorder = Preorder.last

    expect(purchase.total_transaction_cents).to eq(0)
    expect(purchase.price_cents).to eq(0)
    expect(purchase.shipping_cents).to eq(0)
    expect(purchase.purchase_state).to eq("preorder_authorization_successful")
    expect(purchase.email).to eq("test@gumroad.com")
    expect(purchase.link).to eq(@product)
    expect(purchase.street_address.downcase).to eq("1640 17th st")
    expect(purchase.city.downcase).to eq("san francisco")
    expect(purchase.state).to eq("CA")
    expect(purchase.zip_code).to eq("94107")

    expect(preorder.preorder_link).to eq(@preorder_link)
    expect(preorder.seller).to eq(@creator)
    expect(preorder.state).to eq("authorization_successful")
  end

  it "charges the proper amount with taxes for preorder" do
    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    check_out(@product, address: { street: "3029 W Sherman Rd", city: "San Tan Valley", state: "AZ", zip_code: "85144" }, should_verify_address: true) do
      expect(page).to have_text("Subtotal US$16", normalize_ws: true)
      expect(page).to have_text("Sales tax US$1.07", normalize_ws: true)
      expect(page).to have_text("Shipping rate US$4", normalize_ws: true)
      expect(page).to have_text("Total US$21.07", normalize_ws: true)
    end

    expect(page).to have_text("Your purchase was successful!")
    expect(page).to have_text("physical preorder $16", normalize_ws: true)
    expect(page).to have_text("Shipping $4", normalize_ws: true)
    expect(page).to have_text("Sales tax $1.07", normalize_ws: true)

    purchase = Purchase.last
    preorder = Preorder.last

    expect(purchase.total_transaction_cents).to eq(21_07)
    expect(purchase.price_cents).to eq(20_00)
    expect(purchase.tax_cents).to eq(0)
    expect(purchase.gumroad_tax_cents).to eq(1_07)
    expect(purchase.shipping_cents).to eq(4_00)
    expect(purchase.purchase_state).to eq("preorder_authorization_successful")
    expect(purchase.email).to eq("test@gumroad.com")
    expect(purchase.link).to eq(@product)
    expect(purchase.street_address.downcase).to eq("3029 w sherman rd")
    expect(purchase.city.downcase).to eq("san tan valley")
    expect(purchase.state).to eq("AZ")
    expect(purchase.zip_code).to eq("85144")

    expect(preorder.preorder_link).to eq(@preorder_link)
    expect(preorder.seller).to eq(@creator)
    expect(preorder.state).to eq("authorization_successful")
  end

  it "charges the proper shipping amount for 2x quantity" do
    visit "/l/#{@product.unique_permalink}"

    add_to_cart(@product, quantity: 2)
    check_out(@product, should_verify_address: true) do
      expect(page).to have_text("Shipping rate US$5", normalize_ws: true)
      expect(page).to have_text("Total US$37", normalize_ws: true)
    end

    expect(page.all(:css, ".receipt-price")[0].text).to eq("$32")

    expect(page.all(:css, ".product-name")[1].text).to eq("Shipping")
    expect(page.all(:css, ".receipt-price")[1].text).to eq("$5")

    purchase = Purchase.last
    preorder = Preorder.last

    expect(purchase.total_transaction_cents).to eq(37_00)
    expect(purchase.price_cents).to eq(37_00)
    expect(purchase.shipping_cents).to eq(5_00)
    expect(purchase.purchase_state).to eq("preorder_authorization_successful")
    expect(purchase.quantity).to eq(2)
    expect(purchase.email).to eq("test@gumroad.com")
    expect(purchase.link).to eq(@product)
    expect(purchase.street_address.downcase).to eq("1640 17th st")
    expect(purchase.city.downcase).to eq("san francisco")
    expect(purchase.state).to eq("CA")
    expect(purchase.zip_code).to eq("94107")

    expect(preorder.preorder_link).to eq(@preorder_link)
    expect(preorder.seller).to eq(@creator)
    expect(preorder.state).to eq("authorization_successful")
  end
end
