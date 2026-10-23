# frozen_string_literal: true

# Content lives here, not in job arguments, so a queued job can't alter the approved copy.
# Every delivery goes through FeatureAnnouncementDelivery.hand_off at the transport (see HandoffTarget).
class FeatureAnnouncementMailer < ApplicationMailer
  helper InstallmentsHelper

  layout "layouts/email"

  FROM = "Gumroad <gumroad@#{CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN}>"
  SENDER_DOMAIN = :creators
  # Mail's own defaults, pinned because the gate holds row locks for the whole SMTP exchange.
  SMTP_TIMEOUTS = { open_timeout: 5, read_timeout: 5 }.freeze

  CAMPAIGNS = {
    # gumroad-private#3664
    "piracy_reports" => {
      subject: "Report piracy from Gumroad",
      reply_to: "support@gumroad.com",
      audience: :piracy_reports_audience?,
      body: <<~HTML,
        <p>Hi creator,</p>
        <p>Found a pirated copy of your product? You can now report it from Gumroad.</p>
        <p>We check the page and prepare a takedown notice. You review and sign it before we send it to the site.</p>
        <p>Choose <strong>Report piracy</strong> from your product’s menu on the <a href="https://gumroad.com/products">Products page</a>.</p>
        <p>You can submit up to five reports each calendar month. <a href="https://gumroad.com/help/article/354-reporting-piracy">Read the guide</a> for the requirements and what happens next.</p>
        <p>If you try it, reply to this email with what worked and what we should improve.</p>
        <p>The Gumroad team</p>
      HTML
    },
    # gumroad-private#3773
    "mcp_connector" => {
      subject: "Sell from the AI assistant you already use",
      reply_to: "support@gumroad.com",
      audience: :mcp_connector_audience?,
      body: <<~HTML,
        <p>Hi creator,</p>
        <p>Your Gumroad store now works inside Claude. Connect it once, and you can check your sales, draft a product, publish it, and see your payouts without leaving the chat.</p>
        <p>What that looks like:</p>
        <p>• "Show my recent sales." See which products sold and what buyers paid.<br>
        • "Draft my next product." Get a name, price, and description written for you. Add the files in Gumroad, then publish.<br>
        • "Check my latest payouts." See amounts and status.</p>
        <p>Set it up in about a minute at <a href="https://gumroad.com/mcp">gumroad.com/mcp</a>. Add the connector in Claude, approve the permissions you want to grant, and you are done. Custom-connector access depends on your Claude plan and organization settings. Step-by-step guide: <a href="https://gumroad.com/help/article/355-connect-ai-assistants-to-gumroad">Connecting AI assistants to your Gumroad store</a>. You can revoke access at any time from Settings.</p>
        <p>Your prices, your earnings, your payout schedule, and your product setup all stay exactly as they are today. Nothing about your money changes.</p>
        <p>The slow part of selling is usually the gap between having an idea and having it live. This shortens that gap from an afternoon of setup to a sentence in a chat.</p>
        <p>The Gumroad Team</p>
      HTML
    },
  }.freeze

  # Mail#deliver and Mail#deliver! (deliver_now!/deliver_later!) both end in
  # `delivery_method.deliver!(self)`, so gating the transport covers every public path.
  module HandoffTarget
    attr_accessor :feature_announcement_target

    def delivery_method(method = nil, settings = {})
      return super if method

      GatedTransport.new(super)
    end
  end

  class GatedTransport
    delegate :settings, :settings=, to: :@transport

    def initialize(transport)
      @transport = transport
    end

    def deliver!(mail)
      FeatureAnnouncementDelivery.hand_off(mail) { @transport.deliver!(mail) }
    end
  end

  def self.in_audience?(campaign, user)
    send(CAMPAIGNS.fetch(campaign)[:audience], user)
  end

  # Sellers who can file a piracy report for at least one of their products. The query keeps
  # only products that already pass Eligibility's product checks, so whichever one it returns
  # decides the seller-level checks too; a later product can't qualify where it failed.
  def self.piracy_reports_audience?(user)
    return false unless user.eligible_for_store_agent?

    product = piracy_report_candidates(user).first
    product.present? && PiracyReports::Eligibility.new(seller: user, product:).eligible?
  end

  def self.piracy_report_candidates(user)
    collaborated = user.products.joins(:confirmed_collaborators).merge(Affiliate.alive).select(:id)
    sold = Purchase.successful.where("purchases.link_id = links.id")
      .select(1).offset(PiracyReport::MIN_SUCCESSFUL_SALES - 1).limit(1)
    user.products.where(deleted_at: nil, purchase_disabled_at: nil, draft: false)
      .where.not(id: collaborated).where("EXISTS (#{sold.to_sql})").order(:id)
  end

  # Creator accounts: any account that has made a product, the line User#is_buyer? draws.
  # Buyers, followers and signups without a product are left out even if they opted in.
  def self.mcp_connector_audience?(user)
    user.products.exists?
  end

  def announcement(campaign:, user_id:, email:)
    content = CAMPAIGNS.fetch(campaign)
    user = User.find_by(id: user_id)
    return if user.nil? || !EmailFormatValidator.valid?(email)

    @subject = content[:subject]
    @body = content[:body]
    @unsub_link = user_unsubscribe_feature_announcements_url(FeatureAnnouncementSubscription.unsubscribe_token(user, email))
    headers["List-Unsubscribe"] = "<#{@unsub_link}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"

    mail(
      to: email,
      from: FROM,
      reply_to: content[:reply_to],
      subject: @subject,
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: SENDER_DOMAIN, to: email).merge(SMTP_TIMEOUTS),
      template_path: "one_off_mailer",
      template_name: "email"
    )
    message.extend(HandoffTarget).feature_announcement_target = { campaign:, user_id:, email: }
  end
end
