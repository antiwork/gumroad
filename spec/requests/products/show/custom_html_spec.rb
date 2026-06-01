# frozen_string_literal: true

require "spec_helper"

describe "Custom HTML product page", type: :system, js: true do
  let(:seller) { create(:user) }
  let(:product) do
    create(
      :product,
      user: seller,
      quantity_enabled: true,
      custom_html: <<~HTML
        <main>
          <h1>Custom landing</h1>
          <button type="button" data-gumroad-action="buy" data-gumroad-quantity="2">Buy from iframe</button>
        </main>
      HTML
    )
  end

  before do
    Feature.activate_user(:custom_html_pages, seller)
  end

  it "navigates from the sandboxed landing iframe to checkout when the buy control is clicked" do
    visit short_link_path(product)

    expect(page).to have_selector("iframe#gumroad-landing-frame")
    within_frame(find("iframe#gumroad-landing-frame")) do
      expect(page).to have_text("Custom landing")
      click_on "Buy from iframe"
    end

    expect(page).to have_current_path(/^\/checkout/, wait: 10)
    within_cart_item(product.name) do
      expect(page).to have_text("Qty: 2")
    end
  end
end
