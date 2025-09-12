# frozen_string_literal: true

describe("Product Page - Shipping physical subscription", type: :system, js: true, shipping: true) do
  before do
    @creator = create(:user_with_compliance_info)
    Feature.deactivate_user(:merchant_migration, @creator)
    @sub_link = create(:physical_product, user: @creator, name: "physical subscription", price_cents: 16_00, is_recurring_billing: true, subscription_duration: :monthly, require_shipping: true)
    @sub_link.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 4_00, multiple_items_rate_cents: 1_00)
    @sub_link.save!
  end

  it "charges the proper amount and stores shipping without taxes" do
    visit "/l/#{@sub_link.unique_permalink}"

    add_to_cart(@sub_link)
    check_out(@sub_link, should_verify_address: true) do
      expect(page).to have_text("Shipping rate US$4", normalize_ws: true)
      expect(page).to have_text("Total US$20", normalize_ws: true)
    end

    expect(page).to have_alert("Your purchase was successful!")

    purchase = Purchase.last
    subscription = Subscription.last

    expect(purchase.total_transaction_cents).to eq(20_00)
    expect(purchase.price_cents).to eq(20_00)
    expect(purchase.shipping_cents).to eq(4_00)
    expect(purchase.subscription).to eq(subscription)
    expect(purchase.is_original_subscription_purchase).to eq(true)
    expect(purchase.link).to eq(@sub_link)
    expect(purchase.street_address.downcase).to eq("1640 17th st")
    expect(purchase.city.downcase).to eq("san francisco")
    expect(purchase.state).to eq("CA")
    expect(purchase.zip_code).to eq("94107")
    expect(subscription.email).to eq("test@gumroad.com")
  end

  it "charges the proper amount with taxes" do
    visit "/l/#{@sub_link.unique_permalink}"
    add_to_cart(@sub_link)
    check_out(@sub_link, address: { street: "3029 W Sherman Rd", city: "San Tan Valley", state: "AZ", zip_code: "85144" }, should_verify_address: true) do
      expect(page).to have_text("Subtotal US$16", normalize_ws: true)
      expect(page).to have_text("Sales tax US$1.07", normalize_ws: true)
      expect(page).to have_text("Shipping rate US$4", normalize_ws: true)
      expect(page).to have_text("Total US$21.07", normalize_ws: true)
    end

    expect(page).to have_alert("Your purchase was successful!")

    purchase = Purchase.last
    subscription = Subscription.last

    expect(purchase.total_transaction_cents).to eq(21_07)
    expect(purchase.price_cents).to eq(20_00)
    expect(purchase.tax_cents).to eq(0)
    expect(purchase.gumroad_tax_cents).to eq(1_07)
    expect(purchase.shipping_cents).to eq(4_00)
    expect(purchase.subscription).to eq(subscription)
    expect(purchase.is_original_subscription_purchase).to eq(true)
    expect(purchase.link).to eq(@sub_link)
    expect(purchase.street_address.downcase).to eq("3029 w sherman rd")
    expect(purchase.city.downcase).to eq("san tan valley")
    expect(purchase.state).to eq("AZ")
    expect(purchase.zip_code).to eq("85144")

    expect(subscription.email).to eq("test@gumroad.com")
  end

  it "charges the proper shipping amount for 2x quantity" do
    visit "/l/#{@sub_link.unique_permalink}"

    add_to_cart(@sub_link, quantity: 2)
    check_out(@sub_link, should_verify_address: true) do
      expect(page).to have_text("Shipping rate US$5", normalize_ws: true)
      expect(page).to have_text("Total US$37", normalize_ws: true)
    end

    expect(page).to have_alert("Your purchase was successful!")

    purchase = Purchase.last

    expect(purchase.total_transaction_cents).to eq(37_00)
    expect(purchase.price_cents).to eq(37_00)
    expect(purchase.shipping_cents).to eq(5_00)
    expect(purchase.quantity).to eq(2)
  end
end
