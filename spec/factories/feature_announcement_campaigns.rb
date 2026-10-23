# frozen_string_literal: true

FactoryBot.define do
  factory :feature_announcement_campaign do
    sequence(:key) { "campaign_#{_1}" }
    subject { "A new Gumroad feature" }
    body { "<p>Hi creator,</p><p>Try the new feature.</p>" }
    reply_to { "support@gumroad.com" }
    audience { "piracy_reports" }
    state { "sending" }
    approved_at { Time.current }
    content_digest { FeatureAnnouncementCampaign.digest_for(subject, body, reply_to) }

    trait :draft do
      state { "draft" }
      approved_at { nil }
      content_digest { nil }
    end

    trait :piracy_reports do
      key { "piracy_reports" }
      subject { "Report piracy from Gumroad" }
      body do
        <<~HTML
          <p>Hi creator,</p>
          <p>Found a pirated copy of your product? You can now report it from Gumroad.</p>
          <p>We check the page and prepare a takedown notice. You review and sign it before we send it to the site.</p>
          <p>Choose <strong>Report piracy</strong> from your product’s menu on the <a href="https://gumroad.com/products">Products page</a>.</p>
          <p>You can submit up to five reports each calendar month. <a href="https://gumroad.com/help/article/354-reporting-piracy">Read the guide</a> for the requirements and what happens next.</p>
          <p>If you try it, reply to this email with what worked and what we should improve.</p>
          <p>The Gumroad team</p>
        HTML
      end
      state { "sent" }
    end
  end
end
