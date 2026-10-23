# frozen_string_literal: true

require "spec_helper"

describe FeatureAnnouncementMailer, "mcp_connector campaign" do
  include ActiveJob::TestHelper

  let(:creator) { create(:product, user: create(:user, email: "mcp-creator@example.com")).user }

  def announcement(user, to: user.email)
    described_class.announcement(campaign: "mcp_connector", user_id: user.id, email: to)
  end

  def subscribe!(user)
    FeatureAnnouncementSubscription.update_from_settings!(user, subscribed: true, rendered_version: 0)
  end

  def delivery(user)
    FeatureAnnouncementDelivery.find_by(campaign: "mcp_connector", user_id: user.id)
  end

  before { ActionMailer::Base.deliveries.clear }

  describe "rendering" do
    it "sends the campaign copy from the shared feature announcement sender" do
      mail = announcement(creator)

      expect(mail.subject).to eq("Sell from the AI assistant you already use")
      expect(mail[:from].to_s).to eq(described_class::FROM)
      expect(mail.reply_to).to eq(["support@gumroad.com"])
      expect(mail.to).to eq(["mcp-creator@example.com"])
      expect(mail.delivery_method.settings).to include(domain: CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN, open_timeout: 5, read_timeout: 5)

      body = Nokogiri::HTML(mail.body.encoded).at_css(".main")
      expect(body.text.squish).to include(
        "Hi creator, Your Gumroad store now works inside Claude. Connect it once, and you can check your sales, draft a product, " \
        "publish it, and see your payouts without leaving the chat. What that looks like: " \
        "• \"Show my recent sales.\" See which products sold and what buyers paid. " \
        "• \"Draft my next product.\" Get a name, price, and description written for you. Add the files in Gumroad, then publish. " \
        "• \"Check my latest payouts.\" See amounts and status. " \
        "Set it up in about a minute at gumroad.com/mcp. Add the connector in Claude, approve the permissions you want to grant, " \
        "and you are done. Custom-connector access depends on your Claude plan and organization settings. " \
        "Step-by-step guide: Connecting AI assistants to your Gumroad store. You can revoke access at any time from Settings. " \
        "Your prices, your earnings, your payout schedule, and your product setup all stay exactly as they are today. " \
        "Nothing about your money changes."
      )
      expect(body.css("a").map { _1["href"] }).to eq(["https://gumroad.com/mcp", "https://gumroad.com/help/article/355-connect-ai-assistants-to-gumroad"])
      expect(body.text).not_to match(/ChatGPT|Muse/)
    end

    it "links the footer and one-click headers to this recipient's unsubscribe token" do
      mail = announcement(creator)
      footer_link = Nokogiri::HTML(mail.body.encoded).at_css(".footer a[href*='unsubscribe_feature_announcements']")["href"]

      expect(mail["List-Unsubscribe"].value).to eq("<#{footer_link}>")
      expect(mail["List-Unsubscribe-Post"].value).to eq("List-Unsubscribe=One-Click")
      token = URI.parse(footer_link).path.split("/").last
      expect(FeatureAnnouncementSubscription.decode_unsubscribe_token(token))
        .to eq([creator.id, FeatureAnnouncementSubscription.address_digest("mcp-creator@example.com")])
    end
  end

  describe "audience" do
    it "delivers to an opted-in creator at their confirmed address" do
      subscribe!(creator)

      perform_enqueued_jobs { announcement(creator).deliver_later(queue: "low") }

      expect(ActionMailer::Base.deliveries.map(&:to)).to eq([["mcp-creator@example.com"]])
      expect(delivery(creator).attributes.slice("state", "email", "reason")).to eq("state" => "delivered", "email" => "mcp-creator@example.com", "reason" => nil)
    end

    it "keeps a creator whose products are all deleted, as User#is_buyer? does" do
      creator.products.each(&:mark_deleted!)
      create(:purchase, purchaser: creator, email: creator.email)
      subscribe!(creator)
      expect(creator.is_buyer?).to be(false)

      announcement(creator).deliver_now

      expect(delivery(creator).state).to eq("delivered")
    end

    {
      "a buyer with no products" => -> {
        create(:user, email: "mcp-buyer@example.com").tap { create(:purchase, purchaser: _1, email: _1.email) }
      },
      "an account that follows a seller and has no products" => -> {
        create(:user, email: "mcp-follower@example.com").tap { create(:active_follower, email: _1.email, follower_user_id: _1.id) }
      },
      "an account with no products or purchases" => -> { create(:user, email: "mcp-signup@example.com") },
    }.each do |name, build|
      it "skips #{name}, even with Feature announcements on" do
        user = instance_exec(&build)
        subscribe!(user)

        announcement(user).deliver_now

        expect(ActionMailer::Base.deliveries).to be_empty
        expect(delivery(user).attributes.slice("state", "reason")).to eq("state" => "skipped", "reason" => "not_in_audience")
      end
    end

    it "skips a migrated newsletter subscriber who is not a creator" do
      follower = create(:user, email: "mcp-newsletter@example.com")
      FeatureAnnouncementSubscription.create!(user: follower, subscribed: true, source: "newsletter_migration")

      announcement(follower).deliver_now

      expect(delivery(follower).reason).to eq("not_in_audience")
    end
  end

  describe "consent" do
    it "does not treat the legacy announcement preference as an opt-in" do
      expect(creator.announcement_notification_enabled).to be(true)

      announcement(creator).deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery(creator).reason).to eq("not_subscribed")
      expect(FeatureAnnouncementSubscription.where(user_id: creator.id)).to be_empty
    end

    it "skips a creator who opted out earlier" do
      subscribe!(creator)
      FeatureAnnouncementSubscription.unsubscribe!(creator, source: "settings")

      announcement(creator).deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery(creator).reason).to eq("not_subscribed")
    end

    it "honors an opt-out made after the message was rendered" do
      subscribe!(creator)
      mail = announcement(creator)
      mail.message

      FeatureAnnouncementSubscription.unsubscribe!(creator, source: "unsubscribe_link")
      mail.deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery(creator).reason).to eq("not_subscribed")
    end

    {
      "is suspended" => [->(user) { user.update!(user_risk_state: "suspended_for_tos_violation") }, "account_inactive"],
      "is deleted" => [->(user) { user.update!(deleted_at: Time.current) }, "account_inactive"],
      "has an unconfirmed address" => [->(user) { user.update_columns(confirmed_at: nil) }, "email_unconfirmed"],
      "has a pending email change" => [->(user) { user.update_columns(unconfirmed_email: "mcp-pending@example.com") }, "email_change_pending"],
      "changed its address" => [->(user) { user.update_columns(email: "mcp-new@example.com") }, "recipient_mismatch"],
    }.each do |name, (change, reason)|
      it "skips an account that #{name} after the message was rendered" do
        subscribe!(creator)
        mail = announcement(creator)
        mail.message

        change.call(creator)
        mail.deliver_now

        expect(ActionMailer::Base.deliveries).to be_empty
        expect(delivery(creator).attributes.slice("state", "reason")).to eq("state" => "skipped", "reason" => reason)
      end
    end
  end

  describe "deduplication" do
    it "sends the campaign to an account and to an address at most once" do
      subscribe!(creator)
      2.times { announcement(creator).deliver_now }
      other = create(:product, user: create(:user, email: "mcp-other@example.com")).user
      subscribe!(other)

      announcement(other, to: "MCP-Creator@example.com").deliver_now

      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(FeatureAnnouncementDelivery.where(campaign: "mcp_connector").pluck(:user_id)).to eq([creator.id])
    end

    it "counts deliveries per campaign" do
      subscribe!(creator)
      FeatureAnnouncementDelivery.create!(campaign: "piracy_reports", user_id: creator.id, email: creator.email, state: "delivered")

      announcement(creator).deliver_now

      expect(delivery(creator).state).to eq("delivered")
    end

    it "keeps an uncertain earlier attempt quarantined" do
      subscribe!(creator)
      FeatureAnnouncementDelivery.create!(campaign: "mcp_connector", user_id: creator.id, email: creator.email, state: "unknown")

      announcement(creator).deliver_now

      expect(ActionMailer::Base.deliveries).to be_empty
      expect(delivery(creator).state).to eq("unknown")
    end
  end
end
