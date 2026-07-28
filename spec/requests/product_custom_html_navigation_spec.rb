# frozen_string_literal: true

require "spec_helper"

# A custom-HTML product landing page renders inside a sandboxed iframe with an
# opaque origin and no top-level navigation. A plain link to the seller's own
# storefront or another of their products would therefore navigate the IFRAME,
# which the browser blocks, and the visitor lands on an error page — the only
# thing that used to work was target="_blank". The gumroad:navigate bridge lets
# the trusted wrapper navigate the visitor's tab instead. These specs drive
# that flow in a real browser.
describe "Product custom HTML landing page store navigation", type: :system, js: true do
  let(:seller) { create(:user, username: "navstudio", name: "Nav Studio") }
  let!(:other_product) { create(:product, user: seller, name: "Sibling Product") }

  let(:custom_html) do
    <<~HTML
      <main>
        <h1>Landing Page</h1>
        <a id="sibling" href="#{other_product.long_url}">Sibling Product</a>
        <a id="external" href="https://evil.example/phish">External link</a>
        <button id="evil-post" type="button">Post evil</button>
        <script>
          // Simulates malicious seller HTML driving the bridge directly with a
          // foreign-host URL — the trusted wrapper must refuse to navigate.
          document.getElementById("evil-post").addEventListener("click", function () {
            parent.postMessage({ type: "gumroad:navigate", url: "https://evil.example/phish" }, "*");
          });
        </script>
      </main>
    HTML
  end

  let(:product) { create(:product, user: seller, name: "Landing Product", custom_html:) }

  before do
    Feature.activate_user(:custom_html_pages, seller)
    product
  end

  it "navigates the top-level window to the seller's other product when a plain link is clicked" do
    visit "#{seller.subdomain_with_protocol}/l/#{product.unique_permalink}"
    landing_url = page.current_url

    within_frame(find("iframe#gumroad-landing-frame")) do
      expect(page).to have_text("Landing Page")
      click_on "Sibling Product"
    end

    expect(page).to have_current_path(%r{/l/#{other_product.unique_permalink}}, url: true, wait: 10)
    expect(page.current_url).not_to eq(landing_url)
  end

  it "does not navigate the top level for a gumroad:navigate message pointing at a foreign host" do
    visit "#{seller.subdomain_with_protocol}/l/#{product.unique_permalink}"
    landing_url = page.current_url

    within_frame(find("iframe#gumroad-landing-frame")) do
      click_on "Post evil"
    end

    sleep 1 # give a (wrong) navigation a chance to happen before asserting it didn't
    expect(page.current_url).to eq(landing_url)
  end
end
