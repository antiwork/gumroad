# frozen_string_literal: true

require "spec_helper"

describe "Membership magic link page", type: :system, js: true do
  include ManageSubscriptionHelpers

  before { setup_subscription }

  context "when the buyer is logged in" do
    it "allows the user to access the manage page" do
      sign_in @subscription.user
      visit "/subscriptions/#{@subscription.external_id}/manage"

      expect(page).to_not have_current_path(magic_link_subscription_path(@subscription.external_id))
    end
  end

  context "when the logged in user is admin" do
    it "allows the user to access the manage page" do
      admin = create(:user, is_team_member: true)
      sign_in admin
      visit "/subscriptions/#{@subscription.external_id}/manage"

      expect(page).to_not have_current_path(magic_link_subscription_path(@subscription.external_id))
    end
  end

  context "when the encrypted cookie is present" do
    it "allows the user to access the manage page" do
      # first visit using a token to get the cookie
      setup_subscription_token
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      # second visit without token, using the cookie
      visit "/subscriptions/#{@subscription.external_id}/manage"
      expect(page).to_not have_current_path(magic_link_subscription_path(@subscription.external_id))
    end
  end

  context "when the logged in user is the seller" do
    it "doesn't allow the user to access the manage page" do
      sign_in @subscription.seller
      visit "/subscriptions/#{@subscription.external_id}/manage"

      expect(page).to have_current_path(magic_link_subscription_path(@subscription.external_id))
    end
  end

  context "when the token is invalid" do
    it "shows the magic link page with the right message" do
      setup_subscription_token
      visit "/subscriptions/#{@subscription.external_id}/manage?token=invalid"

      expect(page).to have_current_path(magic_link_subscription_path(@subscription.external_id, invalid: true))
      expect(page).to have_text "Your magic link has expired"
      expect(page).to have_text "Send magic link"
    end
  end

  context "when there's only one email linked to the subscription" do
    it "asks to use a magic link to access the manage page" do
      visit "/subscriptions/#{@subscription.external_id}/manage"

      expect(page).to have_current_path(magic_link_subscription_path(@subscription.external_id))
      expect(page).to have_text "You're currently not signed in"
      expect(page).to have_text @subscription.link.name
      expect(page).to_not have_text @subscription.email
      expect(page).to have_text EmailRedactorService.redact(@subscription.email)
      expect(page).to have_text "Send magic link"

      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, @subscription.email).and_return(mail_double)
      click_on "Send magic link"

      expect(page).to have_current_path(magic_link_subscription_path(@subscription.external_id))
      expect(page).to have_text "We've sent a link to"
      expect(page).to have_text "Resend magic link"
    end

    it "resends the magic link" do
      visit "/subscriptions/#{@subscription.external_id}/manage"

      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, @subscription.email).and_return(mail_double)
      click_on "Send magic link"

      expect(page).to have_current_path(magic_link_subscription_path(@subscription.external_id))
      expect(page).to have_text "We've sent a link to"
      expect(page).to have_text "Resend magic link"

      expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, @subscription.email).and_return(mail_double)
      click_on "Resend magic link"

      expect(page).to have_alert "Magic link resent to"
    end

    context "when the token is expired" do
      it "shows the magic link page with the right message" do
        setup_subscription_token
        travel_to(2.day.from_now)
        visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

        expect(page).to have_current_path(magic_link_subscription_path(@subscription.external_id, invalid: true))
        expect(page).to have_text "Your magic link has expired"
        expect(page).to have_text "Send magic link"
      end
    end
  end

  context "when there's more than one different emails linked to the subscription" do
    before do
      @subscription.original_purchase.update!(email: "purchase@email.com")
    end

    it "asks to use a magic link to access the manage page" do
      visit "/subscriptions/#{@subscription.external_id}/manage"

      expect(page).to have_current_path(magic_link_subscription_path(@subscription.external_id))
      expect(page).to have_text "You're currently not signed in"

      expect(page).to have_text "choose one of the emails associated with your account to receive a magic link"
      expect(page).to have_text "Choose an email"
      expect(page).to_not have_text @subscription.email
      expect(page).to_not have_text @subscription.original_purchase.email
      expect(page).to have_text EmailRedactorService.redact(@subscription.email)
      expect(page).to have_text EmailRedactorService.redact(@subscription.original_purchase.email)
      expect(page).to have_text "Send magic link"
    end

    it "doesn't show the same email twice" do
      visit "/subscriptions/#{@subscription.external_id}/manage"

      expect(page).to have_current_path(magic_link_subscription_path(@subscription.external_id))
      expect(page).to have_text "You're currently not signed in"

      expect(page).to have_text "choose one of the emails associated with your account to receive a magic link"
      expect(page).to have_text "Choose an email"
      expect(page).to have_text(EmailRedactorService.redact(@subscription.email), count: 1)
      expect(page).to have_text(EmailRedactorService.redact(@subscription.original_purchase.email), count: 1)
      expect(page).to have_text "Send magic link"
    end

    context "when the user picks the subscription email" do
      it "sends the magic link to the subscription email" do
        visit "/subscriptions/#{@subscription.external_id}/manage"

        redacted_subscription_email = EmailRedactorService.redact(@subscription.email)
        expect(page).to have_text redacted_subscription_email
        expect(page).to have_text EmailRedactorService.redact(@subscription.original_purchase.email)
        expect(page).to have_text "Send magic link"

        mail_double = double
        allow(mail_double).to receive(:deliver_later)
        expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, @subscription.email).and_return(mail_double)

        choose redacted_subscription_email
        click_on "Send magic link"
      end
    end

    context "when the user picks the purchase email" do
      it "sends the magic link to the purchase email" do
        visit "/subscriptions/#{@subscription.external_id}/manage"

        redacted_purchase_email = EmailRedactorService.redact(@subscription.original_purchase.email)
        expect(page).to have_text EmailRedactorService.redact(@subscription.email)
        expect(page).to have_text redacted_purchase_email
        expect(page).to have_text "Send magic link"

        mail_double = double
        allow(mail_double).to receive(:deliver_later)
        expect(CustomerMailer).to receive(:subscription_magic_link).with(@subscription.id, @subscription.original_purchase.email).and_return(mail_double)

        choose "#{redacted_purchase_email}"
        click_on "Send magic link"
      end
    end

    context "when the token is invalid" do
      it "shows the magic link page with the right message" do
        visit "/subscriptions/#{@subscription.external_id}/manage?token=invalid"

        expect(page).to have_current_path(magic_link_subscription_path(@subscription.external_id, invalid: true))
        expect(page).to have_text "Your magic link has expired"

        expect(page).to have_text "choose one of the emails associated with your account to receive a magic link"
        expect(page).to have_text "Choose an email"
        expect(page).to_not have_text @subscription.email
        expect(page).to_not have_text @subscription.original_purchase.email
        expect(page).to have_text EmailRedactorService.redact(@subscription.email)
        expect(page).to have_text EmailRedactorService.redact(@subscription.original_purchase.email)
        expect(page).to have_text "Send magic link"
      end
    end
  end
end
