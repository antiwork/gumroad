# frozen_string_literal: true

require "spec_helper"

describe ApplicationMailer do
  it "includes RescueSmtpErrors" do
    expect(described_class).to include(RescueSmtpErrors)
  end

  describe "delivery method" do
    let(:mailer) { described_class.new }

    before do
      described_class.class_eval do
        def test_email
          mail(to: "test@example.com", subject: "Test") do |format|
            format.text { render plain: "Test email content" }
          end
        end
      end

      ActionMailer::Base.delivery_method = :test
      ActionMailer::Base.deliveries.clear
    end

    describe "delivery_method_options" do
      it "uses MailerInfo.random_delivery_method_options with gumroad domain" do
        expect(MailerInfo).to receive(:random_delivery_method_options).with(domain: :gumroad).and_return({})
        mailer.test_email
      end

      it "evaluates options lazily" do
        options = { address: "smtp.sendgrid.net" }
        allow(MailerInfo).to receive(:random_delivery_method_options).and_return(options)

        mail = mailer.test_email
        expect(mail.delivery_method.settings).to include(options)
      end

      it "sets delivery method options correctly" do
        options = { address: "smtp.sendgrid.net", domain: "gumroad.com" }
        allow(MailerInfo).to receive(:random_delivery_method_options).and_return(options)

        mail = mailer.test_email
        expect(mail.delivery_method.settings).to include(options)
      end
    end

    describe "email provider header attribution" do
      # The X-GUM-Email-Provider header is derived from the SMTP address the
      # message will actually be sent through (see set_custom_headers), so it
      # must stay correct both when the Router picks Resend and when a
      # recipient-domain override (e.g. web.de/GMX, issue #1462) forces SendGrid.
      # Header assignment happens in the overridden #process, so these tests
      # invoke the mailer through the class (as production code does) rather
      # than calling the instance method directly.
      it "attributes the email to SendGrid when the delivery method is SendGrid" do
        options = MailerInfo::DeliveryMethod.options(domain: :gumroad, email_provider: MailerInfo::EMAIL_PROVIDER_SENDGRID)
        allow(MailerInfo).to receive(:random_delivery_method_options).and_return(options)

        mail = described_class.test_email.message
        expect(mail.header[MailerInfo.header_name(:email_provider)].value).to eq(MailerInfo::EMAIL_PROVIDER_SENDGRID)
      end

      it "attributes the email to Resend when the delivery method is Resend" do
        options = MailerInfo::DeliveryMethod.options(domain: :gumroad, email_provider: MailerInfo::EMAIL_PROVIDER_RESEND)
        allow(MailerInfo).to receive(:random_delivery_method_options).and_return(options)

        mail = described_class.test_email.message
        expect(mail.header[MailerInfo.header_name(:email_provider)].value).to eq(MailerInfo::EMAIL_PROVIDER_RESEND)
      end
    end
  end
end
