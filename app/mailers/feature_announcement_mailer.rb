# frozen_string_literal: true

# Copy comes from FeatureAnnouncementCampaign, not job arguments, so a queued job can't alter it.
# Every delivery goes through FeatureAnnouncementDelivery.hand_off at the transport (see HandoffTarget).
class FeatureAnnouncementMailer < ApplicationMailer
  helper InstallmentsHelper

  layout "layouts/email"

  FROM = "Gumroad <gumroad@#{CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN}>"
  SENDER_DOMAIN = :creators
  # Mail's own defaults, pinned because the gate holds row locks for the whole SMTP exchange.
  SMTP_TIMEOUTS = { open_timeout: 5, read_timeout: 5 }.freeze

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
    send(:"#{campaign.audience}_audience?", user)
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

  def announcement(campaign:, user_id:, email:)
    # A lagging replica could render older copy, which the gate then skips for good.
    content = ApplicationRecord.connected_to(role: :writing) { FeatureAnnouncementCampaign.find_by!(key: campaign) }
    user = User.find_by(id: user_id)
    return if user.nil? || !EmailFormatValidator.valid?(email)

    @subject = content.subject
    @body = content.body
    @unsub_link = user_unsubscribe_feature_announcements_url(FeatureAnnouncementSubscription.unsubscribe_token(user, email))
    headers["List-Unsubscribe"] = "<#{@unsub_link}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"

    mail(
      to: email,
      from: FROM,
      reply_to: content.reply_to,
      subject: @subject,
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: SENDER_DOMAIN, to: email).merge(SMTP_TIMEOUTS),
      template_path: "one_off_mailer",
      template_name: "email"
    )
    # The digest of the copy rendered here, so the gate can refuse a message rendered before approval.
    message.extend(HandoffTarget).feature_announcement_target = { campaign:, user_id:, email:, content_digest: content.current_digest }
  end
end
