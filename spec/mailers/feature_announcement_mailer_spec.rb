# frozen_string_literal: true

require "spec_helper"

describe FeatureAnnouncementMailer do
  include ActiveJob::TestHelper

  # A seller in the approved audience: can file a piracy report for their product.
  let(:user) { create_piracy_seller_with_product.first.tap { _1.update_columns(email: "creator@example.com") } }
  let(:content) { described_class::CAMPAIGNS.fetch("piracy_reports") }

  def announcement(to: user.email)
    described_class.announcement(campaign: "piracy_reports", user_id: user.id, email: to)
  end

  def subscribe!
    FeatureAnnouncementSubscription.update_from_settings!(user, subscribed: true, rendered_version: 0)
  end

  def delivery
    FeatureAnnouncementDelivery.find_by(campaign: "piracy_reports", user_id: user.id)
  end

  describe "rendering" do
    it "sends the approved subject, sender, Reply-To and copy" do
      mail = announcement

      expect(mail.subject).to eq("Report piracy from Gumroad")
      expect(mail[:from].to_s).to eq("Gumroad <gumroad@#{CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN}>")
      expect(mail.reply_to).to eq(["support@gumroad.com"])
      expect(mail.to).to eq(["creator@example.com"])
      expect(mail.delivery_method.settings).to include(domain: CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN, open_timeout: 5, read_timeout: 5)

      body = Nokogiri::HTML(mail.body.encoded).at_css(".main")
      expect(body.text.squish).to include(
        "Hi creator, Found a pirated copy of your product? You can now report it from Gumroad. " \
        "We check the page and prepare a takedown notice. You review and sign it before we send it to the site. " \
        "Choose Report piracy from your product’s menu on the Products page. " \
        "You can submit up to five reports each calendar month. Read the guide for the requirements and what happens next. " \
        "If you try it, reply to this email with what worked and what we should improve. The Gumroad team"
      )
      expect(body.css("strong").map(&:text)).to eq(["Report piracy"])
      expect(body.css("a").map { _1["href"] }).to eq(["https://gumroad.com/products", "https://gumroad.com/help/article/354-reporting-piracy"])
    end

    it "renders the same message body OneOffMailer would, adding only the unsubscribe footer" do
      mail = announcement
      one_off = OneOffMailer.email(email: user.email, from: described_class::FROM, subject: content[:subject], body: content[:body],
                                   reply_to: content[:reply_to], sender_domain: :creators)

      announcement_html = Nokogiri::HTML(mail.body.encoded)
      one_off_html = Nokogiri::HTML(one_off.body.encoded)
      expect(announcement_html.at_css(".main").to_html).to eq(one_off_html.at_css(".main").to_html)
      expect(one_off_html.at_css(".footer").text).not_to include("Unsubscribe")
      expect(announcement_html.at_css(".footer a[href*='unsubscribe_feature_announcements']").text).to eq("Unsubscribe")
    end

    it "sets one-click List-Unsubscribe headers pointing at the footer link for this recipient" do
      mail = announcement
      footer_link = Nokogiri::HTML(mail.body.encoded).at_css(".footer a[href*='unsubscribe_feature_announcements']")["href"]

      expect(mail["List-Unsubscribe"].value).to eq("<#{footer_link}>")
      expect(mail["List-Unsubscribe-Post"].value).to eq("List-Unsubscribe=One-Click")
      expect(footer_link).to start_with("#{PROTOCOL}://#{DOMAIN}/users/unsubscribe_feature_announcements/")
      token = URI.parse(footer_link).path.split("/").last
      expect(FeatureAnnouncementSubscription.decode_unsubscribe_token(token))
        .to eq([user.id, FeatureAnnouncementSubscription.address_digest("creator@example.com")])
    end

    it "refuses an unknown campaign" do
      expect { described_class.announcement(campaign: "other", user_id: user.id, email: user.email).message }.to raise_error(KeyError)
    end
  end

  describe "handoff gate" do
    before { ActionMailer::Base.deliveries.clear }

    it "delivers to a subscribed, active account at its confirmed address" do
      subscribe!

      announcement.deliver_now

      expect(ActionMailer::Base.deliveries.map(&:to)).to eq([["creator@example.com"]])
      expect(delivery.attributes.slice("state", "email", "reason")).to eq("state" => "delivered", "email" => "creator@example.com", "reason" => nil)
    end

    it "delivers through the mail delivery job" do
      subscribe!

      perform_enqueued_jobs { announcement.deliver_later(queue: "low") }

      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(delivery.state).to eq("delivered")
    end

    it "does not send to a user who never opted in, even with the shared announcement preference on" do
      expect(user.announcement_notification_enabled).to be(true)

      announcement.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.attributes.slice("state", "reason")).to eq("state" => "skipped", "reason" => "not_subscribed")
    end

    it "honors an opt-out made after the message was rendered" do
      subscribe!
      mail = announcement
      mail.message # renders now

      FeatureAnnouncementSubscription.unsubscribe!(user, source: "unsubscribe_link")
      mail.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("not_subscribed")
    end

    it "rechecks account status after the message was rendered" do
      subscribe!
      mail = announcement
      mail.message

      user.update!(user_risk_state: "suspended_for_fraud")
      mail.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("account_inactive")
    end

    it "skips a deleted account" do
      subscribe!
      mail = announcement
      mail.message

      user.update!(deleted_at: Time.current)
      mail.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("account_inactive")
    end

    it "skips when the account's confirmed address changed after rendering" do
      subscribe!
      mail = announcement
      mail.message

      user.update_columns(email: "new-address@example.com")
      mail.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("recipient_mismatch")
    end

    it "skips a job addressed to anything but the account's confirmed address" do
      subscribe!

      announcement(to: "someone-else@example.com").deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("recipient_mismatch")
    end

    it "skips an account with a pending email change, whichever address the job used" do
      subscribe!
      user.update_columns(unconfirmed_email: "pending@example.com")

      announcement.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("email_change_pending")
    end

    it "skips a seller who is no longer in the approved audience" do
      subscribe!
      user.products.each { _1.update!(purchase_disabled_at: Time.current) }

      announcement.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("not_in_audience")
    end

    it "skips a seller whose payout record has no legal name" do
      subscribe!
      user.alive_user_compliance_info.mark_deleted!

      announcement.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("not_in_audience")
    end

    it "refuses to run inside a caller's transaction, where its claim could be rolled back" do
      subscribe!

      expect { ApplicationRecord.transaction { announcement.deliver_now } }.to raise_error(FeatureAnnouncementDelivery::AmbientTransactionError)

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery).to be_nil
    end

    it "skips an account whose email was never confirmed" do
      subscribe!
      user.update_columns(confirmed_at: nil)

      announcement.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("email_unconfirmed")
    end

    it "refuses a message whose content or unsubscribe link was changed after rendering" do
      subscribe!
      mail = announcement
      mail.message.subject = "Something else"
      mail.deliver_now

      other = create(:user, email: "other@example.com")
      FeatureAnnouncementSubscription.update_from_settings!(other, subscribed: true, rendered_version: 0)
      other_mail = described_class.announcement(campaign: "piracy_reports", user_id: other.id, email: other.email)
      other_mail.message["List-Unsubscribe"] = nil
      other_mail.message["List-Unsubscribe"] = "<#{user_unsubscribe_feature_announcements_url(FeatureAnnouncementSubscription.unsubscribe_token(user, user.email))}>"
      other_mail.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("content_mismatch")
      expect(FeatureAnnouncementDelivery.find_by(user_id: other.id).reason).to eq("unsubscribe_link_mismatch")
    end

    it "sends a campaign to a user at most once" do
      subscribe!

      2.times { announcement.deliver_now }
      perform_enqueued_jobs { announcement.deliver_later }

      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(FeatureAnnouncementDelivery.where(user_id: user.id).count).to eq(1)
    end

    it "sends a campaign to an address at most once across accounts" do
      subscribe!
      announcement.deliver_now
      other = create(:user, email: "other@example.com")
      FeatureAnnouncementSubscription.update_from_settings!(other, subscribed: true, rendered_version: 0)

      described_class.announcement(campaign: "piracy_reports", user_id: other.id, email: "CREATOR@example.com").deliver_now

      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(FeatureAnnouncementDelivery.where(user_id: other.id)).to be_empty
    end

    it "compares and records the address case-insensitively" do
      subscribe!

      announcement(to: "Creator@Example.com").deliver_now

      expect(ActionMailer::Base.deliveries.map(&:to)).to eq([["Creator@Example.com"]])
      expect(delivery.attributes.slice("state", "email")).to eq("state" => "delivered", "email" => "creator@example.com")
    end

    it "gates the bang delivery paths the same way" do
      announcement.deliver_now!
      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("not_subscribed")

      FeatureAnnouncementDelivery.delete_all
      subscribe!
      perform_enqueued_jobs { announcement.deliver_later! }
      announcement.deliver_now!

      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(delivery.state).to eq("delivered")
    end

    it "gates a direct call to the message's transport" do
      mail = announcement.message

      mail.delivery_method.deliver!(mail)

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.reason).to eq("not_subscribed")
    end

    it "claims nothing when Mail is told not to perform deliveries, even through deliver!" do
      subscribe!
      skipped = announcement
      skipped.message.perform_deliveries = false
      skipped.deliver_now
      forced = announcement
      forced.message.perform_deliveries = false

      expect { forced.deliver_now! }.to raise_error(FeatureAnnouncementDelivery::UnsafeMailSettingsError)
      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery).to be_nil
    end

    it "refuses to deliver when Mail would swallow delivery errors" do
      subscribe!
      mail = announcement
      mail.message.raise_delivery_errors = false

      mail.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery).to be_nil
      announcement.deliver_now
      expect(ActionMailer::Base.deliveries.size).to eq(1)
    end

    it "keeps a seller whose only sold product is older than many unsold ones" do
      subscribe!
      create_list(:product, 25, user:)

      announcement.deliver_now

      expect(delivery.state).to eq("delivered")
    end

    it "does not count a sold product shared with a collaborator, but finds another sold one" do
      subscribe!
      create(:collaborator, seller: user, products: user.products.to_a)
      expect(described_class.piracy_reports_audience?(user)).to be(false)

      create(:purchase, link: create(:product, user:))

      expect(described_class.piracy_reports_audience?(user)).to be(true)
    end

    it "leaves unrelated OneOffMailer sends ungated" do
      OneOffMailer.email(user_id: user.id, subject: "Account notice", body: "Hello").deliver_now

      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(ActionMailer::Base.deliveries.last["List-Unsubscribe"]).to be_nil
      expect(FeatureAnnouncementDelivery.count).to eq(0)
    end
  end

  describe "uncertain handoffs" do
    before do
      ActionMailer::Base.deliveries.clear
      subscribe!
    end

    it "quarantines a timeout after the handoff started and never retries it" do
      allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_raise(Net::ReadTimeout)
      expect(ErrorNotifier).to receive(:notify).with(instance_of(Net::ReadTimeout), context: { feature_announcement_delivery_id: kind_of(Integer) })

      perform_enqueued_jobs { announcement.deliver_later }
      expect(delivery.attributes.slice("state", "reason")).to eq("state" => "unknown", "reason" => "Net::ReadTimeout")

      allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_call_original
      perform_enqueued_jobs { announcement.deliver_later }

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(FeatureAnnouncementDelivery.quarantined.pluck(:user_id)).to eq([user.id])
    end

    it "quarantines a handoff that outlasts the overall cap" do
      stub_const("FeatureAnnouncementDelivery::HANDOFF_TIMEOUT_SECONDS", 0.2)
      allow_any_instance_of(Mail::TestMailer).to receive(:deliver!) { sleep 2 }

      perform_enqueued_jobs { announcement.deliver_later }

      expect(delivery.attributes.slice("state", "reason")).to eq("state" => "unknown", "reason" => "FeatureAnnouncementDelivery::HandoffTimeout")
    end

    it "keeps a claim left by a crashed process quarantined" do
      FeatureAnnouncementDelivery.create!(campaign: "piracy_reports", user_id: user.id, email: user.email, state: "claimed")

      announcement.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.state).to eq("claimed")
      expect(FeatureAnnouncementDelivery.quarantined.count).to eq(1)
    end

    it "releases the claim when the connection never opened, so the retry can send" do
      attempts = 0
      allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_wrap_original do |original, *args|
        attempts += 1
        raise Net::OpenTimeout if attempts == 1

        original.call(*args)
      end

      perform_enqueued_jobs { announcement.deliver_later }

      expect(attempts).to eq(2)
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(delivery.state).to eq("delivered")
    end

    it "retries a 4xx refusal through the delivery job and sends once" do
      attempts = 0
      allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_wrap_original do |original, *args|
        attempts += 1
        raise Net::SMTPServerBusy.new(Net::SMTP::Response.parse("451 4.3.0 Try again later")) if attempts == 1

        original.call(*args)
      end

      perform_enqueued_jobs { announcement.deliver_later }

      expect(attempts).to eq(2)
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(delivery.state).to eq("delivered")
    end

    it "rechecks consent when it retries a 4xx refusal" do
      allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_raise(Net::SMTPServerBusy.new(Net::SMTP::Response.parse("421 4.7.0 Throttled")))
      announcement.deliver_later
      perform_enqueued_jobs
      expect(enqueued_jobs.size).to eq(1)
      expect(delivery).to be_nil

      allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_call_original
      FeatureAnnouncementSubscription.unsubscribe!(user, source: "unsubscribe_link")
      perform_enqueued_jobs

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.attributes.slice("state", "reason")).to eq("state" => "skipped", "reason" => "not_subscribed")
    end

    it "keeps a failed row when the mailer's rescue swallows an authentication error" do
      allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_raise(Net::SMTPAuthenticationError.new(Net::SMTP::Response.parse("535 5.7.8 Authentication failed")))
      expect(ErrorNotifier).to receive(:notify).with(instance_of(Net::SMTPAuthenticationError), context: { feature_announcement_delivery_id: kind_of(Integer) })

      expect { perform_enqueued_jobs { announcement.deliver_later } }.not_to raise_error

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery.attributes.slice("state", "reason")).to eq("state" => "failed", "reason" => "Net::SMTPAuthenticationError")
      expect(FeatureAnnouncementDelivery.quarantined).to be_empty
    end

    it "records a provider rejection without retrying" do
      allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_raise(Net::SMTPFatalError.new(Net::SMTP::Response.parse("550 rejected")))

      perform_enqueued_jobs { announcement.deliver_later }
      perform_enqueued_jobs { announcement.deliver_later }

      expect(delivery.attributes.slice("state", "reason")).to eq("state" => "rejected", "reason" => "Net::SMTPFatalError")
    end
  end
end
