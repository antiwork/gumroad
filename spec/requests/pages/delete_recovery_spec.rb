# frozen_string_literal: true

require "spec_helper"

describe "Page deletion recovery", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let!(:seller_page) { create(:user_page, pageable: seller, slug: "about", title: "About", content: "<p>Hello</p>") }

  before do
    login_as seller
    visit pages_path
    click_on "Delete About"
  end

  it "recovers from a network failure and retries the actual delete" do
    page.driver.browser.execute_cdp("Network.enable")
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: ["*#{page_path(seller_page.slug)}"])
    page.execute_script <<~JS
      window.deleteFinished = false;
      document.addEventListener('inertia:exception', event => event.preventDefault());
      document.addEventListener('inertia:finish', () => { window.deleteFinished = true; });
    JS
    within("[role='dialog']") { click_on "Delete" }
    wait_for_valid("window.deleteFinished")
    expect(Page.exists?(seller_page.id)).to eq(true)
    within("[role='dialog']") do
      expect(page).to have_button("Cancel", disabled: false)
      expect(page).to have_button("Delete", disabled: false)
    end

    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
    within("[role='dialog']") { click_on "Delete" }
    expect(page).to have_text("Page deleted!")
    expect(page).not_to have_selector("[role='dialog']")
    expect(Page.exists?(seller_page.id)).to eq(false)
  ensure
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
  end

  it "retains validation-error recovery without deleting the page" do
    allow_any_instance_of(PagesController).to receive(:destroy) do |controller|
      controller.send(:authorize, :page)
      controller.redirect_to pages_path, inertia: { errors: { base: "The page could not be deleted" } }
    end
    within("[role='dialog']") { click_on "Delete" }
    expect(page).to have_text("Failed to delete the page. Please try again.")
    within("[role='dialog']") do
      expect(page).to have_button("Delete", disabled: false)
      click_on "Cancel"
    end
    expect(page).not_to have_selector("[role='dialog']")
    expect(Page.exists?(seller_page.id)).to eq(true)
  end
end
