# frozen_string_literal: true

require "spec_helper"

describe "Profile settings custom page", type: :system, js: true do
  let(:seller) { create(:user, username: "sellerpage", name: "Original Name", bio: "Original bio") }
  let!(:product) { create(:product, user: seller, name: "Cool thing") }

  # Renders the injected catalog + the interpolated profile fields, so the test can assert both
  # the server-side data injection and the live name/bio sync land in the iframe.
  let(:custom_html) do
    <<~HTML
      <main>
        <h1 data-gumroad-field="name">placeholder</h1>
        <p data-gumroad-field="bio">placeholder bio</p>
        <ul id="catalog"></ul>
        <script>
          var data = JSON.parse(document.getElementById("gumroad-data").textContent);
          data.products.forEach(function (p) {
            var li = document.createElement("li");
            li.textContent = p.name;
            document.getElementById("catalog").appendChild(li);
          });
        </script>
      </main>
    HTML
  end

  before do
    Feature.activate_user(:custom_html_pages, seller)
    seller.update!(custom_html:)
    login_as(seller)
  end

  it "titles the page Profile settings and shows pills, hiding Pages while a custom page is live" do
    visit "/profile"

    expect(page).to have_title("Profile settings")
    expect(page).to have_selector("[role=tab]", text: "About")
    expect(page).to have_selector("[role=tab]", text: "Share")
    expect(page).to have_no_selector("[role=tab]", text: "Pages")
  end

  it "previews the live custom page with the injected catalog and live name/bio edits" do
    visit "/profile"

    frame = find("iframe[title='Custom profile page preview']")
    within_frame(frame) do
      expect(page).to have_text("Cool thing") # injected catalog rendered by the page's own JS
      expect(page).to have_text("Original Name") # server-interpolated profile field
    end

    fill_in "Name", with: "Sellerasdfasdfasdf"
    within_frame(frame) do
      expect(page).to have_text("Sellerasdfasdfasdf") # live postMessage sync, no republish
    end
  end
end
