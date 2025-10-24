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
    let(:purchase) { create(:purchase, link: product, email: "buyer@example.com") }

    before do
      purchase.create_url_redirect!
    end

    context "with customized receipt fields" do
      before do
        product.save_custom_view_content_button_text("Download Your Files")
        product.save_receipt_additional_text("Questions? Contact support@example.com for help.")
      end

      it "shows the customized button text and additional message" do
        visit receipt_purchase_url(purchase.external_id, host: "#{PROTOCOL}://#{DOMAIN}")
        fill_in "Email address:", with: purchase.email
        click_button "View receipt"

        expect(page).to have_text("Download Your Files")
        expect(page).to have_text("Questions? Contact support@example.com for help.")
      end
    end

    context "without customization" do
      it "shows the default button text" do
        visit receipt_purchase_url(purchase.external_id, host: "#{PROTOCOL}://#{DOMAIN}")
        fill_in "Email address:", with: purchase.email
        click_button "View receipt"

        expect(page).to have_text("View content")
      end
    end
  end
end
