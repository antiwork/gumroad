# frozen_string_literal: true

# Delivers Help Center contact form submissions to the support inbox
# (support@gumroad.com), which is ingested by Helper — so form submissions land
# in the same support pipeline as direct emails. `reply_to` is set to the
# submitter so agent replies thread back to them.
class SupportContactMailer < ApplicationMailer
  layout "layouts/email"

  self.delivery_job = SupportContactMailDeliveryJob

  ATTACHMENT_EXTENSIONS = {
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/gif" => "gif",
    "image/webp" => "webp",
  }.freeze

  MAX_HEADER_TEXT_LENGTH = 20

  # The sender is always noreply@gumroad.com, so Gmail threads on subject alone;
  # a fixed subject merged unrelated submissions into one conversation. The
  # submitter plus a per-submission token keep each message separate.
  def contact_form(email:, category:, message:, user_id: nil, referrer_path: nil, attachments: [])
    @email = email
    @category = category
    @message = message
    @user = User.find_by(id: user_id) if user_id
    @referrer_path = referrer_path
    @attachment_filenames = []

    attachments.each_with_index do |attachment, index|
      filename = attachment_filename(attachment, index)
      @attachment_filenames << filename
      self.attachments[filename] = { mime_type: attachment[:mime_type], content: Base64.strict_decode64(attachment[:content]) }
    end

    mail to: SUPPORT_EMAIL,
         reply_to: email,
         subject: contact_form_subject(email:, category:)
  end

  private
    def contact_form_subject(email:, category:)
      submitter = email.to_s.tr("\r\n", " ").strip
      "Help Center contact form: #{category} - #{submitter} [#{SecureRandom.hex(4)}]"
    end

    # The submitter controls the uploaded filename and the controller only
    # verified the bytes, so the attachment name is rebuilt from a safe stem and
    # the extension of the verified type — never the supplied path or extension.
    def attachment_filename(attachment, index)
      extension = ATTACHMENT_EXTENSIONS.fetch(attachment[:mime_type], "png")
      stem = File.basename(attachment[:filename].to_s, ".*").gsub(/[^A-Za-z0-9_-]/, "_").first(60)
      stem = "screenshot-#{index + 1}" if stem.blank?
      # Browsers name every pasted screenshot image.png.
      filename = "#{stem}.#{extension}"
      copy = 1
      filename = "#{stem}-#{copy += 1}.#{extension}" while @attachment_filenames.include?(filename)
      filename
    end

    # MailerInfo copies the mailer args into provider headers but only trims
    # top-level strings. Everything here is a keyword, so without this the
    # message and the screenshots' base64 end up in X-SMTPAPI / X-GUM-Mailer-Args.
    def set_custom_headers(mailer_action, mailer_args)
      header_args = mailer_args.map do |arg|
        next arg unless arg.is_a?(Hash)

        arg.to_h do |key, value|
          value = value.size if key == :attachments
          value = value.first(MAX_HEADER_TEXT_LENGTH) if value.is_a?(String)
          [key, value]
        end
      end
      super(mailer_action, header_args)
    end
end
