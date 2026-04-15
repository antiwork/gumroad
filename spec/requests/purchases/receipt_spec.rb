# frozen_string_literal: true

require "spec_helper"

describe("Viewing a purchase receipt", type: :system, js: true) do
  # Shared context for all tests
  let(:purchase) { create(:membership_purchase) }
  let(:manage_membership_url) { Rails.application.routes.url_helpers.manage_subscription_url(purchase.subscription.external_id, host: "#{PROTOCOL}://#{DOMAIN}") }

  before do
    create(:url_redirect, purchase:)
  end

  describe "membership purchase" do
    it "requires email confirmation to access receipt page" do
      visit receipt_purchase_url(purchase.external_id, host: "#{PROTOCOL}://#{DOMAIN}")
      expect(page).to have_content("Confirm your email address")

      fill_in "Email address:", with: purchase.email
      click_button "View receipt"

      expect(page).to have_link "subscription settings", href: manage_membership_url
      expect(page).to have_link "Manage membership", href: manage_membership_url
    end

    it "shows error message when incorrect email is provided" do
      visit receipt_purchase_url(purchase.external_id, host: "#{PROTOCOL}://#{DOMAIN}")
      expect(page).to have_content("Confirm your email address")

      fill_in "Email address:", with: "wrong@example.com"
      click_button "View receipt"

      expect(page).to have_content("Wrong email. Please try again.")
      expect(page).to have_content("Confirm your email address")
    end
  end

  describe "when user is a team member" do
    let(:team_member) { create(:user) }

    before do
      team_member.update!(is_team_member: true)
      sign_in team_member
    end

    it "allows access to receipt without email confirmation" do
      visit receipt_purchase_url(purchase.external_id, host: "#{PROTOCOL}://#{DOMAIN}")
      expect(page).to have_link "subscription settings", href: manage_membership_url
      expect(page).to have_link "Manage membership", href: manage_membership_url
    end
  end

  describe "Receipt customization" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller: seller, email: "customer@example.com") }

    before do
      purchase.create_url_redirect!
    end

    context "when product has receipt customization" do
      before do
        product.custom_view_content_button_text = "Access Your Purchase"
        product.custom_receipt_text = "Welcome! Your purchase includes lifetime updates."
        product.save
      end

      it "displays custom content in the receipt page" do
        visit receipt_purchase_url(purchase.external_id, host: "#{PROTOCOL}://#{DOMAIN}")

        fill_in "Email address:", with: purchase.email
        click_button "View receipt"

        expect(page).to have_text("Access Your Purchase")
        expect(page).to have_text("Welcome! Your purchase includes lifetime updates.")
        expect(page).not_to have_text("View content")
      end
    end

    context "when product has no receipt customization" do
      it "displays default content in the receipt page" do
        visit receipt_purchase_url(purchase.external_id, host: "#{PROTOCOL}://#{DOMAIN}")

        fill_in "Email address:", with: purchase.email
        click_button "View receipt"

        expect(page).to have_text("View content")
      end
    end
  end
end
