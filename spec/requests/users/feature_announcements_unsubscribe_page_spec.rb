# frozen_string_literal: true

require "spec_helper"

describe "Unsubscribing from feature announcements by email link", type: :system, js: true do
  let(:user) { create(:user, email: "creator@example.com") }

  before { FeatureAnnouncementSubscription.update_from_settings!(user, subscribed: true, rendered_version: 0) }

  it "asks for confirmation, then unsubscribes without a session" do
    mail = FeatureAnnouncementMailer.announcement(campaign: "piracy_reports", user_id: user.id, email: user.email)
    footer_link = Nokogiri::HTML(mail.body.encoded).at_css(".footer a[href*='unsubscribe_feature_announcements']")["href"]

    visit footer_link

    expect(page).to have_text("Unsubscribe from feature announcements?")
    expect(page).to have_text("Other emails are not affected.")
    expect(FeatureAnnouncementSubscription.subscribed?(user)).to be(true)

    click_on "Unsubscribe"

    expect(page).to have_text("You will no longer receive feature announcement emails.")
    expect(FeatureAnnouncementSubscription.subscribed?(user)).to be(false)
    expect(user.reload.announcement_notification_enabled).to be(true)
  end
end
