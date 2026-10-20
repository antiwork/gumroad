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

  it "puts the Unsubscribe button on its own line below the whole explanation" do
    visit user_unsubscribe_feature_announcements_path(FeatureAnnouncementSubscription.unsubscribe_token(user, user.email))

    [nil, { width: 390, height: 844, deviceScaleFactor: 2, mobile: true }].each do |metrics|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", **metrics) if metrics
      layout = page.evaluate_script(<<~JS)
        (() => {
          const button = [...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "Unsubscribe");
          const text = [...button.closest("p").childNodes].find((n) => n.nodeType === Node.TEXT_NODE && n.textContent.includes("Other emails are not affected."));
          const range = document.createRange();
          range.selectNodeContents(text);
          const lines = [...range.getClientRects()];
          const rect = button.getBoundingClientRect();
          return { textLeft: lines[0].left, textBottom: Math.max(...lines.map((l) => l.bottom)), buttonLeft: rect.left, buttonTop: rect.top, width: innerWidth };
        })()
      JS

      expect(layout["buttonTop"]).to be >= layout["textBottom"], "button overlaps the explanation at #{layout["width"]}px: #{layout}"
      expect(layout["buttonLeft"]).to be_within(1).of(layout["textLeft"]), "button is not on its own line at #{layout["width"]}px: #{layout}"
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
