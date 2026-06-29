# frozen_string_literal: true

require "spec_helper"

describe "Profile custom HTML page (public render)", type: :system, js: true do
  let(:seller) { create(:user, username: "lumenstudio", name: "Lumen Studio", bio: "We make beautiful things.") }

  let!(:alpha) { create(:product, user: seller, name: "Alpha Kit") }
  let!(:beta) { create(:product, user: seller, name: "Beta Pack") }
  let!(:gamma) { create(:product, user: seller, name: "Gamma Uniquely Named") }

  let(:custom_html) do
    <<~HTML
      <main>
        <h1 data-gumroad-field="name">placeholder name</h1>
        <p data-gumroad-field="bio">placeholder bio</p>
        <input id="q" type="search" aria-label="Search" />
        <button id="next" type="button">Next</button>
        <ul id="catalog"></ul>
        <p id="result"></p>
        <script>
          var data = JSON.parse(document.getElementById("gumroad-data").textContent);
          var items = data.products.map(function (p) { return p.name; });
          var PAGE_SIZE = 2, page = 1, query = "";
          var ul = document.getElementById("catalog");
          var result = document.getElementById("result");
          function render() {
            var matches = items.filter(function (n) { return n.toLowerCase().indexOf(query) !== -1; });
            var start = (page - 1) * PAGE_SIZE;
            ul.innerHTML = "";
            matches.slice(start, start + PAGE_SIZE).forEach(function (n) {
              var li = document.createElement("li");
              li.className = "item";
              li.textContent = n;
              ul.appendChild(li);
            });
            result.textContent = "Showing " + Math.min(matches.length, PAGE_SIZE) + " of " + matches.length;
          }
          document.getElementById("q").addEventListener("input", function (e) {
            query = e.target.value.toLowerCase(); page = 1; render();
          });
          document.getElementById("next").addEventListener("click", function () {
            page += 1; render();
          });
          render();
        </script>
      </main>
    HTML
  end

  before do
    Feature.activate_user(:custom_html_pages, seller)
    seller.update!(custom_html:)
  end

  it "renders the published custom HTML inside the public sandboxed iframe with interpolated fields" do
    visit seller.subdomain_with_protocol

    frame = find("iframe#gumroad-landing-frame")
    within_frame(frame) do
      expect(page).to have_text("Lumen Studio")
      expect(page).to have_text("We make beautiful things.")
      expect(page).to have_selector("li.item")
    end
  end

  it "runs the page's search and front-end pagination JavaScript under the sandbox CSP" do
    visit seller.subdomain_with_protocol

    within_frame(find("iframe#gumroad-landing-frame")) do
      expect(page).to have_selector("li.item", count: 2)
      expect(page).to have_text("Showing 2 of 3")

      click_button "Next"
      expect(page).to have_selector("li.item", count: 1)

      fill_in "Search", with: "uniquely"
      expect(page).to have_selector("li.item", count: 1)
      expect(page).to have_text("Gamma Uniquely Named")
      expect(page).to have_text("Showing 1 of 1")
      expect(page).to have_no_text("Alpha Kit")
    end
  end
end
