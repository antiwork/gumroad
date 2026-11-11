# frozen_string_literal: true

# SendGrid's click tracking swaps each link for a ~450-byte tracking URL, which lands inside the line
# that already carries the inlined email CSS. docomo rejects the resulting >1000-byte line with
# "500 Line Too Long"; quoted-printable keeps every transmitted line under 100 bytes.
module QuotedPrintableHtmlMail
  def self.delivering_email(message)
    html_part = message.html_part || (message.mime_type == "text/html" ? message : nil)
    html_part&.body&.encoding = "quoted-printable"
  end
end

# after_initialize, not the initializer body: interceptors run in registration order, and this has to
# run after premailer-rails registers the inliner that replaces the html body encoded here.
Rails.application.config.after_initialize do
  ActionMailer::Base.register_interceptor(QuotedPrintableHtmlMail)
end
