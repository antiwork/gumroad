# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Public affiliate request onboarding form", type: :system, js: true do
  let(:creator) { create(:named_user) }
  let!(:product) { create(:product, user: creator) }
  let!(:enabled_self_service_affiliate_product) { create(:self_service_affiliate_product, enabled: true, seller: creator, product:) }

  context "when the requester is not signed in" do
    it "allows requester to submit a request to become an affiliate of the creator" do
      visit new_affiliate_request_path(username: creator.username)

      expect(page).to have_text("Become an affiliate for #{creator.display_name}")
      expect(page).to have_text("Applying to be an affiliate is easy. Fill out the form below and let #{creator.display_name} know how you'll be promoting their products.")
      expect(page).to have_text("To help speed up your approval, include things like social urls, audience size, audience engagement, etc...")

      # Ensure form validations work
      click_on("Submit affiliate request")
      expect(page).to have_alert(text: "Name can't be blank")

      # Request submission status message when the requester already has an account
      create(:user, email: "jane@example.com")
      fill_in("Name", with: "Jane Doe")
      fill_in("Email", with: "jane@example.com")
      fill_in("How do you intend to promote their products? How big is your audience?", with: "Hello!")
      click_on("Submit affiliate request")
      expect(page).to have_text("Your request has been submitted! We will send you an email notification when you are approved.")
      expect(page).to_not have_text("In the meantime, create your Gumroad account using email jane@example.com and confirm it. You'll receive your affiliate links once your Gumroad account is active.")
      expect(AffiliateRequest.last.attributes.with_indifferent_access).to include(name: "Jane Doe", email: "jane@example.com", promotion_text: "Hello!", seller_id: creator.id)

      # Request submission status message when the requester does not have an account
      visit new_affiliate_request_path(username: creator.username)
      fill_in("Name", with: "John Doe")
      fill_in("Email", with: "john@example.com")
      fill_in("How do you intend to promote their products? How big is your audience?", with: "Hello!")
      click_on("Submit affiliate request")
      expect(page).to have_text("Your request has been submitted! We will send you an email notification when you are approved.")
      expect(page).to have_text("In the meantime, create your Gumroad account using email john@example.com and confirm it. You'll receive your affiliate links once your Gumroad account is active.")
      expect(AffiliateRequest.last.attributes.with_indifferent_access).to include(name: "John Doe", email: "john@example.com", promotion_text: "Hello!", seller_id: creator.id)

      # Try submitting yet another request to the same creator using same email address
      visit new_affiliate_request_path(username: creator.username)
      fill_in("Name", with: "JD")
      fill_in("Email", with: "john@example.com")
      fill_in("How do you intend to promote their products? How big is your audience?", with: "Howdy!")
      click_on("Submit affiliate request")
      expect(page).to have_alert(text: "You have already requested to become an affiliate of this creator.")
      expect(page).to_not have_text("Your request has been submitted!")
    end
  end

  context "when the requester is signed in" do
    let(:seller) { create(:named_user) }
    let(:requester) { create(:named_user) }

    context "when requester has not completed onboarding" do
      before do
        requester.update!(name: nil, username: nil)
      end

      context "with other seller as current_seller" do
        include_context "with switching account to user as admin for seller"

        let(:requester) { user_with_role_for_seller }

        it "it submits form and saves name to requester's profile" do
          visit custom_domain_new_affiliate_request_url(host: creator.subdomain_with_protocol)

          fill_in("Name", with: "Jane Doe")
          fill_in("How do you intend to promote their products? How big is your audience?", with: "Hello!")
          click_on("Submit affiliate request")

          expect(page).to have_text("Your request has been submitted! We will send you an email notification when you are approved.")
          expect(AffiliateRequest.last.attributes.with_indifferent_access).to include(name: "Jane Doe", email: requester.email, promotion_text: "Hello!", seller_id: creator.id)
          expect(user_with_role_for_seller.reload.name).to eq("Jane Doe")
        end
      end
    end

    it "allows requester to submit a request to become an affiliate of the creator without needing to enter identification details" do
      login_as(requester)

      visit custom_domain_new_affiliate_request_url(host: creator.subdomain_with_protocol)

      # Ensure form validations work
      click_on("Submit affiliate request")
      expect(page).to have_alert(text: "Promotion text can't be blank")

      # Request submission status message
      fill_in("How do you intend to promote their products? How big is your audience?", with: "Hello!")
      click_on("Submit affiliate request")
      expect(page).to have_text("Your request has been submitted! We will send you an email notification when you are approved.")
      expect(AffiliateRequest.last.attributes.with_indifferent_access).to include(name: requester.name, email: requester.email, promotion_text: "Hello!", seller_id: creator.id)
    end
  end
end
