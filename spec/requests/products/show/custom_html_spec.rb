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

  context "when a seller script reads sandbox-restricted storage on load" do
    let(:product) do
      create(
        :product,
        user: seller,
        custom_html: <<~HTML
          <main>
            <h1>Custom landing</h1>
            <div id="reveal-ls" style="display:none">localStorage reveal worked</div>
            <div id="reveal-ck" style="display:none">cookie reveal worked</div>
            <button type="button" data-gumroad-action="buy">Buy</button>
          </main>
          <script>
            if (localStorage.getItem("theme") !== "never") {
              document.getElementById("reveal-ls").style.display = "block";
            }
          </script>
          <script>
            var cookie = document.cookie;
            document.getElementById("reveal-ck").style.display = "block";
          </script>
        HTML
      )
    end

    it "reveals content gated behind localStorage and document.cookie instead of blanking" do
      visit short_link_path(product)

      within_frame(find("iframe#gumroad-landing-frame")) do
        expect(page).to have_text("localStorage reveal worked")
        expect(page).to have_text("cookie reveal worked")
      end
    end
  end
end
