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

    add_to_cart(product, offer_code: default_offer_code)
    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    expect(page).to have_selector("[aria-label='Discount code']", text: default_offer_code.code, wait: 5)
  end

  it "allows user to override default discount code with a better URL discount code" do
    better_offer_code = create(
      :percentage_offer_code,
      user: seller,
      products: [product],
      code: "BETTER20",
      amount_percentage: 20
    )
    visit "/l/#{product.unique_permalink}/#{better_offer_code.code}"

    expect(page).to have_content(product.name)

    add_to_cart(product, offer_code: better_offer_code)
    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    expect(page).to have_selector("[aria-label='Discount code']", text: better_offer_code.code, wait: 5)
  end

  it "uses default discount code when an inferior URL discount code is provided" do
    inferior_offer_code = create(
      :percentage_offer_code,
      user: seller,
      products: [product],
      code: "INFERIOR5",
      amount_percentage: 5
    )
    visit "/l/#{product.unique_permalink}/#{inferior_offer_code.code}"

    expect(page).to have_content(product.name)

    add_to_cart(product, offer_code: default_offer_code)
    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    expect(page).to have_selector("[aria-label='Discount code']", text: default_offer_code.code, wait: 5)
  end
end
