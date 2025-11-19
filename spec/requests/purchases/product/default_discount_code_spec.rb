# frozen_string_literal: true

require("spec_helper")

describe("Default discount code usage from product page", type: :system, js: true) do
  let(:seller) { create(:user, display_offer_code_field: true) }
  let(:product) { create(:product_with_pdf_file, user: seller, price_cents: 1000) }
  let(:default_offer_code) do
    create(:percentage_offer_code, user: seller, products: [product], code: "DEFAULT10", amount_percentage: 10)
  end

  before do
    allow(Braintree::ClientToken).to receive(:generate).and_return("test_client_token_12345")
    product.update!(default_offer_code: default_offer_code)
  end

  it "applies default discount code on checkout when landing on product page" do
    visit "/l/#{product.unique_permalink}"

    expect(page).to have_content(product.name)

    # We expect the default offer code to be present in the URL/checkout flow
    add_to_cart(product, offer_code: default_offer_code)
    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    expect(page).to have_selector("[aria-label='Discount code']", text: default_offer_code.code, wait: 5)
  end

  it "allows user to override default discount code with URL discount code" do
    url_offer_code = create(
      :percentage_offer_code,
      user: seller,
      products: [product],
      code: "URL20",
      amount_percentage: 20
    )
    visit "/l/#{product.unique_permalink}/#{url_offer_code.code}"

    expect(page).to have_content(product.name)

    add_to_cart(product, offer_code: url_offer_code)
    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    expect(page).to have_selector("[aria-label='Discount code']", text: url_offer_code.code, wait: 5)
  end
end
