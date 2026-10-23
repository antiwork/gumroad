# frozen_string_literal: true

require "spec_helper"

describe "Pages search and sharing fields", type: :system, js: true do
  let(:seller) { create(:named_seller, name: "Jane Doe") }

  before do
    Feature.activate_user(:custom_html_pages, seller)
    login_as(seller)
  end

  it "saves the search title and description of a rich text page and previews the listing" do
    page_record = create(:user_page, pageable: seller, slug: "about", title: "About", content: "<p>Hi</p>")

    visit edit_page_path("about")

    within "#search-listing" do
      expect(page).to have_text("About — Jane Doe")
      expect(page).to have_text("Search engines choose text from the page.")
    end
    fill_in "Title", with: "About me"
    within "#search-listing" do
      expect(page).to have_text("About me — Jane Doe")

      fill_in "Title in search results", with: "Hand-lettered posters"
      fill_in "Description in search results", with: "Posters and prints by Jane Doe."

      expect(page).to have_text("Hand-lettered posters")
      expect(page).to have_text("Posters and prints by Jane Doe.")
    end
    click_on "Save changes"

    expect(page).to have_alert(text: "Changes saved!")
    expect(page_record.reload).to have_attributes(seo_title: "Hand-lettered posters", seo_description: "Posters and prints by Jane Doe.")
  end

  it "saves the search fields of a custom HTML page and leaves its HTML alone" do
    page_record = create(:user_page, pageable: seller, slug: "free-resources", title: "Free resources",
                                     custom_html: "<main><h1>Free resources</h1></main>")

    visit edit_page_path("free-resources")

    fill_in "Title in search results", with: "Free poster templates"
    click_on "Save changes"

    expect(page).to have_alert(text: "Changes saved!")
    expect(page_record.reload.seo_title).to eq("Free poster templates")
    expect(page_record.custom_html).to include("<h1>Free resources</h1>")
  end

  it "saves the home page's search fields to the seller profile" do
    visit edit_page_path("profile")

    fill_in "Title in search results", with: "Hand-lettered posters"
    fill_in "Description in search results", with: "Posters and prints by Jane Doe."
    click_on "Save changes"

    expect(page).to have_alert(text: "Changes saved!")
    expect(SellerProfile.find_by!(seller:)).to have_attributes(seo_title: "Hand-lettered posters", seo_description: "Posters and prints by Jane Doe.")
  end
end
