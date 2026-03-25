# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Third-party Analytics Settings Scenario", type: :system, js: true) do
  let(:seller) { create(:named_seller) }
  let!(:snippet) { create(:third_party_analytic, user: seller, name: "Snippet 1") }

  include_context "with switching account to user as admin for seller"

  describe "third-party analytics updates" do
    it "saves the global third-party analytics toggle" do
      visit settings_third_party_analytics_path
      uncheck "Enable third-party analytics services"
      click_on "Update settings"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.disable_third_party_analytics).to eq(true)

      visit settings_third_party_analytics_path
      check "Enable third-party analytics services"
      click_on "Update settings"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.disable_third_party_analytics).to eq(false)
    end

    it "saves the Google Analytics property ID" do
      google_analytics_id = "G-1234567-12"
      visit settings_third_party_analytics_path
      fill_in "Google Analytics Property ID", with: google_analytics_id
      click_on "Update settings"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.google_analytics_id).to eq(google_analytics_id)
    end

    it "saves the Facebook pixel" do
      facebook_pixel_id = "123456789"
      visit settings_third_party_analytics_path
      fill_in "Facebook Pixel", with: facebook_pixel_id
      click_on "Update settings"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.facebook_pixel_id).to eq(facebook_pixel_id)
    end

    it "saves the $0 purchase setting" do
      visit settings_third_party_analytics_path
      uncheck "Send 'Purchase' events for free ($0) sales"
      click_on "Update settings"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.skip_free_sale_analytics).to eq(true)

      visit settings_third_party_analytics_path
      check "Send 'Purchase' events for free ($0) sales"
      click_on "Update settings"
      expect(page).to have_alert(text: "Changes saved!")
      expect(seller.reload.skip_free_sale_analytics).to eq(false)
    end

    it "saves the domain verification setting and Facebook meta tag" do
      facebook_meta_tag = '<meta name="facebook-domain-verification" content="dkd8382hfdjs" />'
      visit settings_third_party_analytics_path
      check "Verify domain in third-party services"
      fill_in "Facebook Business", with: facebook_meta_tag
      click_on "Update settings"
      expect(page).to have_alert(text: "Changes saved!")
      seller.reload
      expect(seller.enable_verify_domain_third_party_services).to eq(true)
      expect(seller.facebook_meta_tag).to eq(facebook_meta_tag)

      visit settings_third_party_analytics_path
      uncheck "Verify domain in third-party services"
      expect(seller.reload.facebook_meta_tag).to eq(facebook_meta_tag)
    end

    it "deletes snippets" do
      visit settings_third_party_analytics_path
      within find_snippet_row(name: snippet.name) do
        click_on "Delete snippet"
      end
      click_on "Update settings"
      expect(page).to have_alert(text: "Changes saved!")
      expect(snippet.reload.deleted_at).to_not be_nil
    end

    it "updates existing snippets" do
      visit settings_third_party_analytics_path
      within find_snippet_row(name: snippet.name) do
        click_on "Edit snippet"
        fill_in "Name", with: "New name"
        select "All products", from: "Product"
        select "All pages", from: "Location"
        fill_in "Code", with: "New code"
      end
      click_on "Update settings"
      expect(page).to have_alert(text: "Changes saved!")

      snippet.reload
      expect(snippet.name).to eq("New name")
      expect(snippet.location).to eq("all")
      expect(snippet.link_id).to be_nil
      expect(snippet.analytics_code).to eq("New code")
    end

    it "adds new snippets" do
      visit settings_third_party_analytics_path
      click_on "Add snippet"
      within find_snippet_row(name: "Untitled") do
        fill_in "Name", with: "New name"
        select "All products", from: "Product"
        select "All pages", from: "Location"
        fill_in "Code", with: "New code"
      end
      click_on "Update settings"
      expect(page).to have_alert(text: "Changes saved!")

      snippet = ThirdPartyAnalytic.last
      expect(snippet.name).to eq("New name")
      expect(snippet.location).to eq("all")
      expect(snippet.link_id).to be_nil
      expect(snippet.analytics_code).to eq("New code")
    end
  end

  def find_snippet_row(name:)
    find("[role=listitem] h4", text: name).ancestor("[role=listitem]")
  end
end
