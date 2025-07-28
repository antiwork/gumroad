# frozen_string_literal: true

class PostSendgridApi
  include Rails.application.routes.url_helpers
  include ActionView::Helpers::SanitizeHelper
  include MailerHelper, CustomMailerRouteBuilder
  _routes.default_url_options = Rails.application.config.action_mailer.default_url_options
  MAX_RECIPIENTS = 1_000 # SendGrid's API limit: https://docs.sendgrid.com/for-developers/sending-email/personalizations

  def self.process(**args) = new(**args).send_emails

  # Sends post emails via SendGrid API.
  # How it works:
  # - renders and locally caches the email template
  # - sends the emails via SendGrid API, with substitutions for each recipient
  # - records the emails as sent in EmailInfo
  # - records the emails in EmailEvent
  # - updates delivery statistics
  # - sends push notifications
  # It does not:
  # - check whether the post has already been sent to the email addresses (it's the caller's responsibility)
  # - create any UrlRedirect records (same)
  #
  # `recipients` keys:
  # required => :email (string)
  # optional => :purchase, :subscription, :follower, :affiliate, :url_redirect (records)
  def initialize(post:, recipients:, cache: {}, blast: nil, preview: false)
    @post = post
    @recipients = recipients
    @cache = cache
    @blast = blast
    @preview = preview

    @cache[@post] ||= {}
  end

  def send_emails
    mail_json = build_mail

    if Rails.application.config.action_mailer.perform_deliveries != false && !Rails.env.test?
      sendgrid = SendGrid::API.new(api_key: GlobalConfig.get("SENDGRID_GR_CREATORS_API_KEY"))
      result = nil
      duration = Benchmark.realtime do
        result = sendgrid.client.mail._("send").post(request_body: mail_json)
      end
      Rails.logger.info(
        "[#{self.class.name}] Sent post #{@post.id} to #{@recipients.size} recipients" \
        " (duration: #{duration.round(3)}s, status: #{result.status_code})")
      raise SendGridApiResponseError.new(result.body) unless (200..299).include?(result.status_code.to_i)
    else
      Rails.logger.info(
        "[#{self.class.name}] Would have sent post #{@post.id} to #{@recipients.size} recipients" \
        " (perform_deliveries = false)")
    end

    unless @preview
      update_delivery_statistics
      send_push_notifications
      create_email_info_records
      upsert_email_events_documents
    end

    true
  end

  if Rails.env.development? || Rails.env.test?
    @mails = {}
    class << self
      attr_reader :mails
    end
  end

  def build_mail
    return if @recipients.empty?
    validate_recipients
    fetch_rendered_template

    from = SendGrid::Email.new(
      email: creators_from_email_address(@post.seller.username),
      name: from_email_address_name(@post.seller.name)
    )
    reply_to = SendGrid::Email.new(email: @post.seller.support_or_form_email)

    mail = SendGrid::Mail.new
    mail.from = from
    mail.subject = @post.subject
    mail.reply_to = reply_to
    mail.add_content SendGrid::Content.new(type: "text/plain", value: @cache[@post][:template][:plaintext])
    mail.add_content SendGrid::Content.new(type: "text/html", value: @cache[@post][:template][:html])
    mail.add_category SendGrid::Category.new(name: self.class.name)
    mail.add_custom_arg SendGrid::CustomArg.new(key: "installment_id", value: @post.id)
    mail.add_custom_arg SendGrid::CustomArg.new(key: "seller_id", value: @post.seller_id)

    @recipients.each do |recipient|
      mail.add_personalization(build_personalization_for_recipient(recipient))
    end

    mail_json = mail.to_json
    log_mail_debug_info(mail_json)
    mail_json
  end

  private
    def fetch_rendered_template
      @cache[@post][:assigns] ||= {
        has_post_url: @post.shown_on_profile?,
        has_download_button: @cache[@post][:has_files?],
        has_comment_button: @post.shown_on_profile? && @post.allow_comments?,
        has_seller_update_reason: @post.seller_or_product_or_variant_type?,
        gumroad_url: root_url,
      }
      @cache[@post][:template] ||= begin
        rendered_html = ApplicationController.renderer.render(
          template: "posts/post_email",
          layout: false,
          assigns: { post: @post }.merge(@cache[@post][:assigns])
        )
        premailer = Premailer::Rails::CustomizedPremailer.new(rendered_html)
        { html: premailer.to_inline_css, plaintext: premailer.to_plain_text }
      end
      # Also cache other slow operations needed to render the template
      @cache[@post][:sanitized_product_name] = strip_tags(@post.link.name) if !@cache[@post].key?(:sanitized_product_name) && @post.product_or_variant_type?
    end

    def build_personalization_for_recipient(recipient)
      assigns = @cache[@post][:assigns]

      personalization = SendGrid::Personalization.new
      personalization.add_to(SendGrid::Email.new(email: recipient[:email]))
      personalization.add_substitution SendGrid::Substitution.new(key: "{{subject}}", value: @post.subject)

      if assigns[:has_post_url]
        post_url = build_mailer_post_route(post: @post, purchase: recipient[:purchase])
        personalization.add_substitution SendGrid::Substitution.new(key: "{{post_url}}", value: post_url)
      end

      if assigns[:has_download_button]
        download_url = recipient[:url_redirect]&.download_page_url
        personalization.add_substitution SendGrid::Substitution.new(key: "{{download_url}}", value: download_url)
        personalization.add_substitution SendGrid::Substitution.new(key: "{{t_view_attachments_prompt}}", value: "View content")
      end

      if assigns[:has_comment_button]
        personalization.add_substitution SendGrid::Substitution.new(key: "{{t_post_a_comment}}", value: "Reply with a comment")
      end

      if assigns[:has_seller_update_reason]
        if @post.seller_type?
          seller_update_reason = "You've received this post because you've purchased a product from #{@post.seller.name.presence || @post.seller.email || "Gumroad"}."
        elsif @post.product_or_variant_type?
          product_name = recipient[:product_name] || @cache[@post][:sanitized_product_name]
          download_url_or_product_url = recipient[:url_redirect]&.download_page_url || @post.link.long_url
          seller_update_reason = @post.member_cancellation_trigger? ?
                                   "You've received this email because you cancelled your membership to <a href=\"#{download_url_or_product_url}\">#{product_name}</a>." :
                                   @post.link.is_recurring_billing ?
                                   "You've received this email because you subscribed to <a href=\"#{download_url_or_product_url}\">#{product_name}</a>." :
                                   "You've received this email because you've purchased <a href=\"#{download_url_or_product_url}\">#{product_name}</a>."
        end
        personalization.add_substitution SendGrid::Substitution.new(key: "{{seller_update_reason}}", value: seller_update_reason)
      end

      personalization.add_substitution SendGrid::Substitution.new(key: "{{t_powered_by}}", value: "Powered by")
      personalization.add_substitution SendGrid::Substitution.new(key: "{{t_unsubscribe}}", value: "Unsubscribe")

      unsubscribe_url = if recipient[:purchase]
        unsubscribe_purchase_url(recipient[:purchase].secure_external_id(scope: "unsubscribe"))
      elsif recipient[:follower]
        cancel_follow_url(recipient[:follower].external_id)
      elsif recipient[:affiliate]
        unsubscribe_posts_affiliate_url(recipient[:affiliate].external_id)
      else
        "#"
      end
      personalization.add_substitution SendGrid::Substitution.new(key: "{{unsubscribe_url}}", value: unsubscribe_url)

      %i[purchase subscription follower affiliate].each do |record_name|
        personalization.add_custom_arg(SendGrid::CustomArg.new(key: "#{record_name}_id", value: recipient[record_name].id)) if recipient[record_name]
      end
      if recipient[:purchase]
        personalization.add_custom_arg SendGrid::CustomArg.new(key: "type", value: "CreatorContactingCustomersMailer.purchase_installment")
        personalization.add_custom_arg SendGrid::CustomArg.new(key: "identifier", value: "[#{recipient[:purchase].id}, #{@post.id}]")
      elsif recipient[:follower]
        personalization.add_custom_arg SendGrid::CustomArg.new(key: "type", value: "CreatorContactingCustomersMailer.follower_installment")
        personalization.add_custom_arg SendGrid::CustomArg.new(key: "identifier", value: "[#{recipient[:follower].id}, #{@post.id}]")
      elsif recipient[:affiliate]
        personalization.add_custom_arg SendGrid::CustomArg.new(key: "type", value: "CreatorContactingCustomersMailer.direct_affiliate_installment")
        personalization.add_custom_arg SendGrid::CustomArg.new(key: "identifier", value: "[#{recipient[:affiliate].id}, #{@post.id}]")
      end

      personalization
    end

    def update_delivery_statistics
      @post.increment_total_delivered(by: @recipients.size)
      PostEmailBlast.acknowledge_email_delivery(@blast.id, by: @recipients.size) if @blast
    end

    def send_push_notifications
      emails = @recipients.map { _1[:email] }
      users_by_email = User.where(email: emails).select(:id, :email).index_by(&:email)
      return if users_by_email.empty?

      notification_jobs_arguments = @recipients.map do |recipient|
        user = users_by_email[recipient[:email]]
        next if user.nil?

        data = {
          "installment_id" => @post.external_id,
          "subscription_id" => recipient[:subscription]&.external_id,
          "purchase_id" => recipient[:purchase]&.external_id,
          "follower_id" => recipient[:follower]&.external_id,
        }.compact
        body = "By #{@post.seller.name}"
        [user.id, Device::APP_TYPES[:consumer], @post.subject, body, data]
      end.compact

      PushNotificationWorker.set(queue: "low").perform_bulk(notification_jobs_arguments)
    end

    def create_email_info_records
      attributes = @recipients.map do |recipient|
        next unless recipient.key?(:purchase)
        { purchase_id: recipient[:purchase].id }
      end.compact
      return if attributes.empty?

      base_attributes = {
        type: CreatorContactingCustomersEmailInfo.name,
        installment_id: @post.id,
        email_name: EmailEventInfo::PURCHASE_INSTALLMENT_MAILER_METHOD,
        state: "sent",
        sent_at: Time.current,
      }
      EmailInfo.create_with(base_attributes).insert_all!(attributes)
    end

    def upsert_email_events_documents
      EmailEvent.log_send_events(@recipients.map { _1[:email] }, Time.current)
    end

    def validate_recipients
      raise "Too many recipients (#{@recipients.size} > #{MAX_RECIPIENTS})" if @recipients.size > MAX_RECIPIENTS
      @cache[@post][:has_files?] = @post.has_files? unless @cache[@post].key?(:has_files?)
      @recipients.each do |recipient|
        raise "Recipients must have an email" if recipient[:email].blank?
        raise "Recipients of a post with files must have a url_redirect" if @cache[@post][:has_files?] && recipient[:url_redirect].blank?
        raise "Recipients can't have a purchase and/or a follower and/or an affiliate record" if recipient.slice(:purchase, :follower, :affiliate).values.compact.size > 1
      end
    end

    def log_mail_debug_info(mail_json)
      return unless Rails.env.development? || Rails.env.test?
      return if ENV["POST_SENDGRID_API_SKIP_DEBUG"] == "1" # Needed for accurate performance testing in development

      Rails.logger.info("[#{self.class.name}] SendGrid API request body:")
      Rails.logger.info(mail_json)

      content = mail_json["content"].find { _1["type"] == "text/html" }["value"]
      mail_json["personalizations"].each do |personalization|
        content_with_substitutions = content.dup
        personalization["substitutions"].each { content_with_substitutions.gsub!(_1, _2) }
        recipient_email = personalization["to"][0]["email"]
        self.class.mails[recipient_email] = {
          subject: mail_json["subject"],
          from: mail_json.dig("from", "email"),
          reply_to: mail_json.dig("reply_to", "email"),
          content: content_with_substitutions,
          custom_args: mail_json["custom_args"].merge(personalization["custom_args"] || {}),
        }

        if ENV["POST_SENDGRID_API_SAVE_EMAILS"] == "1"
          mails_dir = Rails.root.join("tmp", "mails")
          FileUtils.mkdir_p(mails_dir)
          file = File.new(File.join(mails_dir, "#{Time.current.to_f}-#{@post.id}-#{recipient_email}.html"), "w")
          file.syswrite(content_with_substitutions)
        end
      end
    end
end
