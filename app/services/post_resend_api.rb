# frozen_string_literal: true

class PostResendApi
  include Rails.application.routes.url_helpers
  include ActionView::Helpers::SanitizeHelper
  include MailerHelper, CustomMailerRouteBuilder
  _routes.default_url_options = Rails.application.config.action_mailer.default_url_options
  MAX_RECIPIENTS = 100 # Resend's batch send limit

  def self.process(**args) = new(**args).send_emails

  def initialize(post:, recipients:, cache: {}, blast: nil, preview: false)
    @post = post
    @recipients = recipients
    @cache = cache
    @blast = blast
    @preview = preview

    @cache[@post] ||= {}
  end

  def send_emails
    return true if @recipients.empty?

    validate_recipients!
    fetch_rendered_template

    emails = build_emails
    if Rails.application.config.action_mailer.perform_deliveries != false && !Rails.env.test?
      Resend.api_key = GlobalConfig.get("RESEND_CREATORS_API_KEY")
      duration = Benchmark.realtime do
        response = Resend::Batch.send(emails)
        unless response.success?
          raise ResendApiResponseError.new(response.body)
        end
      end

      Rails.logger.info(
        "[#{self.class.name}] Sent post #{@post.id} to #{@recipients.size} recipients" \
        " (duration: #{duration.round(3)}s)")
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

  private
    def build_emails
      @recipients.map do |recipient|
        email = build_email_for_recipient(recipient)
        log_mail_debug_info(email, recipient) if Rails.env.development? || Rails.env.test?
        email
      end
    end

    def build_email_for_recipient(recipient)
      headers = MailerInfo.build_headers(
        mailer_class: EmailEventInfo::CREATOR_CONTACTING_CUSTOMERS_MAILER_CLASS,
        mailer_method: determine_mailer_method(recipient),
        mailer_args: [recipient.values_at(:purchase, :follower, :affiliate).compact.first&.id, @post.id].compact,
        email_provider: MailerInfo::EMAIL_PROVIDER_RESEND,
      )

      email = {
        from: "#{from_email_address_name(@post.seller.name)} <#{creators_from_email_address(@post.seller.username)}>",
        reply_to: @post.seller.support_or_form_email,
        to: [recipient[:email]],
        subject: @post.subject,
        html: personalize_content(@cache[@post][:template][:html], recipient),
        text: personalize_content(@cache[@post][:template][:plaintext], recipient),
        headers: headers
      }

      email
    end

    def determine_mailer_method(recipient)
      if recipient[:purchase]
        EmailEventInfo::PURCHASE_INSTALLMENT_MAILER_METHOD
      elsif recipient[:follower]
        EmailEventInfo::FOLLOWER_INSTALLMENT_MAILER_METHOD
      elsif recipient[:affiliate]
        EmailEventInfo::DIRECT_AFFILIATE_INSTALLMENT_MAILER_METHOD
      end
    end

    def personalize_content(content, recipient)
      assigns = @cache[@post][:assigns]
      substitutions = {
        "{{subject}}" => @post.subject,
        "{{t_powered_by}}" => "Powered by",
        "{{t_unsubscribe}}" => "Unsubscribe",
        "{{unsubscribe_url}}" => build_unsubscribe_url(recipient)
      }

      if assigns[:has_post_url]
        substitutions["{{post_url}}"] = build_mailer_post_route(post: @post, purchase: recipient[:purchase])
      end

      if assigns[:has_download_button]
        substitutions["{{download_url}}"] = recipient[:url_redirect]&.download_page_url
        substitutions["{{t_view_attachments_prompt}}"] = "View content"
      end

      if assigns[:has_comment_button]
        substitutions["{{t_post_a_comment}}"] = "Reply with a comment"
      end

      if assigns[:has_seller_update_reason]
        substitutions["{{seller_update_reason}}"] = build_seller_update_reason(recipient)
      end

      content = content.dup
      substitutions.each { |key, value| content.gsub!(key, value.to_s) }
      content
    end

    def build_unsubscribe_url(recipient)
      if recipient[:purchase]
        unsubscribe_purchase_url(recipient[:purchase].secure_external_id(scope: "unsubscribe"))
      elsif recipient[:follower]
        cancel_follow_url(recipient[:follower].external_id)
      elsif recipient[:affiliate]
        unsubscribe_posts_affiliate_url(recipient[:affiliate].external_id)
      else
        "#"
      end
    end

    def build_seller_update_reason(recipient)
      if @post.seller_type?
        "You've received this email because you've purchased a product from #{@post.seller.name.presence || @post.seller.email || "Gumroad"}."
      elsif @post.product_or_variant_type?
        product_name = recipient[:product_name] || @cache[@post][:sanitized_product_name]
        download_url_or_product_url = recipient[:url_redirect]&.download_page_url || @post.link.long_url
        @post.member_cancellation_trigger? ?
          "You've received this email because you cancelled your membership to <a href=\"#{download_url_or_product_url}\">#{product_name}</a>." :
          @post.link.is_recurring_billing ?
          "You've received this email because you subscribed to <a href=\"#{download_url_or_product_url}\">#{product_name}</a>." :
          "You've received this email because you've purchased <a href=\"#{download_url_or_product_url}\">#{product_name}</a>."
      end
    end

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
      @cache[@post][:sanitized_product_name] = strip_tags(@post.link.name) if !@cache[@post].key?(:sanitized_product_name) && @post.product_or_variant_type?
    end

    def validate_recipients!
      raise "Too many recipients (#{@recipients.size} > #{MAX_RECIPIENTS})" if @recipients.size > MAX_RECIPIENTS
      @cache[@post][:has_files?] = @post.has_files? unless @cache[@post].key?(:has_files?)
      @recipients.each do |recipient|
        raise "Recipients must have an email" if recipient[:email].blank?
        raise "Recipients of a post with files must have a url_redirect" if @cache[@post][:has_files?] && recipient[:url_redirect].blank?
        raise "Recipients can't have a purchase and/or a follower and/or an affiliate record" if recipient.slice(:purchase, :follower, :affiliate).values.compact.size > 1
      end
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

    def log_mail_debug_info(email, recipient)
      Rails.logger.info("[#{self.class.name}] Resend API request body:")
      Rails.logger.info(email.to_json)

      self.class.mails[recipient[:email]] = {
        subject: email[:subject],
        from: email[:from],
        reply_to: email[:reply_to],
        content: email[:html],
        headers: email[:headers]
      }

      if ENV["POST_RESEND_API_SAVE_EMAILS"] == "1"
        mails_dir = Rails.root.join("tmp", "mails")
        FileUtils.mkdir_p(mails_dir)
        file = File.new(File.join(mails_dir, "#{Time.current.to_f}-#{@post.id}-#{recipient[:email]}.html"), "w")
        file.syswrite(email[:html])
      end
    end
end
