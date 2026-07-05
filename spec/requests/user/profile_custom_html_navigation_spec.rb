# frozen_string_literal: true

require "spec_helper"

# The custom-HTML profile renders inside a sandboxed iframe with an opaque
# origin (no allow-same-origin) and no allow-top-navigation. A plain product
# link would therefore navigate the IFRAME to the product page, which then
# runs without cookies or storage and checkout breaks. The gumroad:navigate
# postMessage bridge lets the trusted wrapper navigate the top-level window
# instead — these specs drive that flow in a real browser.
describe "Profile custom HTML page store navigation", type: :system, js: true do
  let(:seller) { create(:user, username: "bridgestudio", name: "Bridge Studio") }
  let!(:product) { create(:product, user: seller, name: "Bridged Product") }

  let(:custom_html) do
    <<~HTML
      <main>
        <h1>Storefront</h1>
        <ul id="catalog"></ul>
        <a id="external" href="https://evil.example/phish">External link</a>
        <button id="evil-post" type="button">Post evil</button>
        <script>
          var data = JSON.parse(document.getElementById("gumroad-data").textContent);
          var ul = document.getElementById("catalog");
          data.products.forEach(function (p) {
            var li = document.createElement("li");
            var a = document.createElement("a");
            a.href = p.url;
            a.textContent = p.name;
            li.appendChild(a);
            ul.appendChild(li);
          });
          // Simulates malicious seller HTML driving the bridge directly with a
          // foreign-host URL — the trusted wrapper must refuse to navigate.
          document.getElementById("evil-post").addEventListener("click", function () {
            parent.postMessage({ type: "gumroad:navigate", url: "https://evil.example/phish" }, "*");
          });
        </script>
      </main>
    HTML
  end

  before do
    Feature.activate_user(:custom_html_pages, seller)
    seller.update!(custom_html:)
  end

  it "navigates the top-level window (not the sandboxed iframe) to the product page when a plain store link is clicked" do
    visit seller.subdomain_with_protocol
    profile_url = page.current_url

    within_frame(find("iframe#gumroad-landing-frame")) do
      expect(page).to have_text("Storefront")
      click_on "Bridged Product"
    end

    # Without the bridge the click navigates the iframe itself: the top-level
    # URL stays on the profile and the product page renders on the opaque
    # origin where cookies/storage are unavailable. With the bridge the
    # trusted wrapper navigates the visitor's tab to the real product URL.
    expect(page).to have_current_path(%r{/l/#{product.unique_permalink}}, url: true, wait: 10)
    expect(page.current_url).not_to eq(profile_url)
    expect(page).to have_text("Bridged Product")
  end

  it "does not navigate the top level for a gumroad:navigate message pointing at a foreign host" do
    visit seller.subdomain_with_protocol
    profile_url = page.current_url

    within_frame(find("iframe#gumroad-landing-frame")) do
      click_on "Post evil"
    end

    sleep 1 # give a (wrong) navigation a chance to happen before asserting it didn't
    expect(page.current_url).to eq(profile_url)
  end
end
