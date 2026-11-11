# frozen_string_literal: true

# SendGrid's click tracking swaps each link for a ~455-byte tracking URL, which lands inside the line
# that already carries the inlined email CSS. docomo rejects the resulting >1000-byte line with
# "500 Line Too Long"; quoted-printable keeps every transmitted line under 100 bytes.
module QuotedPrintableHtmlMail
  def self.delivering_email(message)
    html_part = message.html_part || (message.mime_type == "text/html" ? message : nil)
    return if html_part.nil?

    # The body's encoding names what its source is already in, so the gem decodes the source with it.
    # Hand over an encoded source: labelling raw html quoted-printable decodes any =XX in it (a subject
    # such as "price=99" in <title>) into a stray byte.
    payload = html_part.body.decoded
    html_part.content_transfer_encoding = "quoted-printable"
    html_part.body = Mail::Encodings::QuotedPrintable.encode(payload)
  end
end

# after_initialize, not the initializer body: interceptors run in registration order, and this has to
# run after premailer-rails registers the inliner that replaces the html body encoded here.
Rails.application.config.after_initialize do
  ActionMailer::Base.register_interceptor(QuotedPrintableHtmlMail)
end
