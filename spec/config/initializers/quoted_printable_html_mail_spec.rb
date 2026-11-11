# frozen_string_literal: true

require "spec_helper"

describe QuotedPrintableHtmlMail do
  # docomo rejects a line over 1000 bytes; SendGrid's click tracking swaps each link for a ~455-byte
  # tracking URL inside the line that already carries the inlined email CSS, so the encoded html has to
  # leave room for that swap.
  let(:docomo_line_limit_bytes) { 1000 }
  let(:tracking_url_bytes) { 455 }
  let(:max_encoded_line_bytes) { docomo_line_limit_bytes - tracking_url_bytes }

  it "is registered as a mail interceptor, after the inliner whose html body it encodes" do
    interceptors = Mail.delivery_interceptors
    expect(interceptors).to include(Premailer::Rails::Hook, QuotedPrintableHtmlMail)
    expect(interceptors.index(QuotedPrintableHtmlMail)).to be > interceptors.index(Premailer::Rails::Hook)
  end

  it "quoted-printable encodes the delivered html part so a tracked link cannot create an over-long line" do
    mail = UserSignupMailer.confirmation_instructions(create(:user), {})
    mail.deliver_now

    html_part = mail.html_part
    expect(html_part.body.encoding).to eq("quoted-printable")
    expect(html_part.encoded.split("\r\n").map(&:bytesize).max).to be < max_encoded_line_bytes
  end

  # A body the gem took for already quoted-printable would decode =XX into a stray byte. The escapes come
  # before any attribute because Ruby's decoder stops at the first invalid escape such as `="`.
  it "round-trips the payload, escaping = rather than reading a hex sequence in it" do
    source = %(<title>price=99 token=E3</title>\n<a href="https://example.com/confirm?token=1234ABCD&amp;x=9">Confirm</a>)
    mail = Mail.new do
      to "buyer@example.com"
      from "noreply@gumroad.com"
      subject "round trip"
      html_part do
        content_type "text/html; charset=UTF-8"
        body source
      end
    end

    QuotedPrintableHtmlMail.delivering_email(mail)

    encoded = mail.encoded
    expect(encoded.gsub("=\r\n", "")).to include("token=3D1234ABCD")
    expect(mail.html_part.decoded).to eq(source)
    expect(encoded.split("\r\n").map(&:bytesize).max).to be < max_encoded_line_bytes
  end

  # Regression guard on a real mail: the confirmation link is the line SendGrid's swap lands in, so it has
  # to arrive with the same links it left with.
  it "delivers the confirmation mail with its links intact" do
    mail = UserSignupMailer.confirmation_instructions(create(:user), {})
    source_links = mail.message.body.to_s.scan(/href="([^"]+)"/).flatten.reject { |href| href.end_with?(".css") }

    mail.deliver_now
    received = Mail.read_from_string(mail.encoded).html_part.decoded

    expect(received.scan(/href="([^"]+)"/).flatten).to eq(source_links)
    expect(received.scan(/[\x00-\x08\x0b\x0c\x0e-\x1f]/)).to be_empty
  end
end
