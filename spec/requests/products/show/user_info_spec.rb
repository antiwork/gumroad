# frozen_string_literal: true

require("spec_helper")

describe("ProductUserInfoScenario", type: :system, js: true) do
  it("it fills the logged in user's information in the form") do
    user = create(:user, name: "amir", street_address: "1640 17th st", zip_code: "94103", country: "United States", city: "San Francisco", state: "CA")
    link = create(:product, unique_permalink: "somelink", require_shipping: true)
    login_as(user)

    visit "#{link.user.subdomain_with_protocol}/l/#{link.unique_permalink}"

    click_on "I want this!"

    expect(page).to have_field "Street address", with: "1640 17th st"
    expect(page).to have_field "ZIP code", with: "94103"
    expect(page).to have_field "State", with: "CA"
    expect(page).to have_field "Country", with: "US"
  end

  it "applies discount based on the offer_code parameter in the query string" do
    product = create(:product, price_cents: 2000)
    offer_code = create(:offer_code, code: "free", products: [product], amount_cents: 2000)

    visit "/l/#{product.unique_permalink}"
    expect(page).to(have_selector("[itemprop='price']", text: "$20"))

    visit "/l/#{product.unique_permalink}/?offer_code=#{offer_code.code}"
    expect(page).to have_selector("[role='status']", text: "$20 off will be applied at checkout (Code FREE)")
    expect(page).to have_selector("[itemprop='price']", text: "$20 $0")
    add_to_cart(product, offer_code:)
    check_out(product, is_free: true)
  end
end
