# frozen_string_literal: true

require("spec_helper")

describe("Purchasing a multi-recurrence subscription product from product page", type: :system, js: true) do
  before do
    @product = create(:subscription_product_with_versions, price_cents: 10_00)
    @price_yearly = create(:price, link: @product, price_cents: 70_00, recurrence: BasePrice::Recurrence::YEARLY)
  end

  it "allows the product to be bought" do
    visit "/l/#{@product.unique_permalink}"

    add_to_cart(@product, option: "Untitled 1")
    check_out(@product)

    expect(Purchase.last.price_cents).to eq(10_00)
    expect(Subscription.last.period).to eq(1.month)
  end

  it "shows the duration, allow the product to be bought, and create correct subscription" do
    @product.update_attribute(:duration_in_months, 12)
    visit "/l/#{@product.unique_permalink}"

    add_to_cart(@product, option: "Untitled 1")
    check_out(@product)

    expect(Purchase.last.price_cents).to eq(10_00)
    expect(Subscription.last.period).to eq(1.month)
    expect(Subscription.last.charge_occurrence_count).to eq(12)
  end

  it "allows the product to be bought with a different payment option" do
    visit "/l/#{@product.unique_permalink}"
    expect(page).to have_radio_button(text: "$10")
    select "Yearly", from: "Recurrence"
    expect(page).to have_radio_button(text: "$70")

    add_to_cart(@product, option: "Untitled 1")
    check_out(@product)

    expect(Purchase.last.price_cents).to eq(70_00)
    expect(Subscription.last.period).to eq(12.months)
  end

  it "allows the product to be bought with a different payment option with an offer code" do
    offer_code = create(:offer_code, products: [@product], amount_cents: nil, amount_percentage: 50, code: "half")
    visit "/l/#{@product.unique_permalink}/#{offer_code.code}"

    expect(page).to have_radio_button(text: "$10")
    select "Yearly", from: "Recurrence"
    expect(page).to have_radio_button(text: "$70")

    expect(page).to have_selector("[role='status']", text: "50% off will be applied at checkout (Code #{offer_code.code.upcase})")
    expect(page).to have_radio_button("Untitled 1", text: "$70 $35")
    expect(page).to have_radio_button("Untitled 2", text: "$70 $35")

    add_to_cart(@product, option: "Untitled 1", offer_code:)
    check_out(@product)

    expect(Purchase.last.price_cents).to eq(35_00)
    expect(Subscription.last.period).to eq(12.months)
  end

  it "allows the buyer to switch back and forth and still buy the correct occurence" do
    visit "/l/#{@product.unique_permalink}"

    select "Yearly", from: "Recurrence"
    add_to_cart(@product, recurrence: "Monthly", option: "Untitled 1")
    check_out(@product)

    expect(Purchase.last.price_cents).to eq(10_00)
    expect(Subscription.last.period).to eq(1.month)
  end

  it "allows the buyer to purchase a fixed length subscription with an offer code and have the correct charge occurrence message" do
    @product.duration_in_months = 12
    @product.save
    @product.user.update!(display_offer_code_field: true)
    code = "offer"
    create(:offer_code, code:, products: [@product], amount_percentage: 50, amount_cents: nil)
    visit "/l/#{@product.unique_permalink}"
    select "Yearly", from: "Recurrence"
    add_to_cart(@product, recurrence: "Monthly", option: "Untitled 1")

    expect(page).to have_text("Total US$10", normalize_ws: true)

    fill_in "Discount code", with: code
    click_on "Apply"

    expect(page).to have_text("Total US$5", normalize_ws: true)

    check_out(@product)

    expect(Purchase.last.price_cents).to eq(5_00)
    expect(Subscription.last.period).to eq(1.month)
  end
end
