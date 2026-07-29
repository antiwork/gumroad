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

        # Deliberately does NOT pass `to:` to random_delivery_method_options —
        # this stands in for the many mailer methods that don't, and is what the
        # ApplicationMailer safety net has to catch.
        def test_email_to(recipient)
          mail(to: recipient, subject: "Test") do |format|
            format.text { render plain: "Test email content" }
          end
        end

        # Stands in for the mailers that address one person and copy another —
        # AffiliateMailer addresses the affiliate and copies the seller.
        def test_email_to_with_cc(recipient, cc_recipient)
          mail(to: recipient, cc: cc_recipient, subject: "Test") do |format|
            format.text { render plain: "Test email content" }
          end
        end

        # No mailer bcc's anyone today, but bcc is an envelope recipient just
        # like cc, so the redirect has to cover it before someone adds the first
        # one. This pins that third field.
        def test_email_to_with_bcc(recipient, bcc_recipient)
          mail(to: recipient, bcc: bcc_recipient, subject: "Test") do |format|
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

    # web.de and GMX policy-reject every IP Resend sends us from, so a buyer at
    # one of those domains pays and never receives their receipt. Individual
    # mailer methods pass `to:` to random_delivery_method_options, but there are
    # dozens of them and a new one is easy to write without knowing that; this is
    # the net that catches the ones that don't.
    # See https://github.com/antiwork/gumroad-private/issues/1462
    describe "United Internet recipient redirect" do
      let(:resend_options) { MailerInfo::DeliveryMethod.options(domain: :gumroad, email_provider: MailerInfo::EMAIL_PROVIDER_RESEND) }
      let(:sendgrid_options) { MailerInfo::DeliveryMethod.options(domain: :gumroad, email_provider: MailerInfo::EMAIL_PROVIDER_SENDGRID) }

      before do
        # Pin the provider choice to Resend so the only thing that can move this
        # message to SendGrid is the redirect under test.
        allow(MailerInfo).to receive(:random_delivery_method_options).and_return(resend_options)
      end

      it "moves a Resend-bound message for a web.de recipient onto SendGrid" do
        mail = described_class.test_email_to("buyer@web.de").message

        expect(mail.delivery_method.settings[:address]).to eq(SENDGRID_SMTP_ADDRESS)
        expect(mail.delivery_method.settings).to include(sendgrid_options)
      end

      it "keeps the provider header consistent with the SMTP address it was moved to" do
        mail = described_class.test_email_to("buyer@gmx.net").message

        expect(mail.header[MailerInfo.header_name(:email_provider)].value).to eq(MailerInfo::EMAIL_PROVIDER_SENDGRID)
      end

      it "redirects when the recipient is in Name <email> form, ignoring case" do
        mail = described_class.test_email_to("Buyer Name <buyer@WEB.DE>").message

        expect(mail.delivery_method.settings[:address]).to eq(SENDGRID_SMTP_ADDRESS)
      end

      it "redirects when only one recipient of several is at a blocked domain" do
        mail = described_class.test_email_to(["buyer@gmail.com", "buyer@gmx.de"]).message

        expect(mail.delivery_method.settings[:address]).to eq(SENDGRID_SMTP_ADDRESS)
      end

      # One SMTP send carries the message to every envelope recipient at once, so
      # a blocked address in cc is enough to lose the whole thing — the copied
      # party and the addressed party both. AffiliateMailer is the live example:
      # it addresses the affiliate and copies the seller, passing no recipient of
      # its own to random_delivery_method_options.
      it "redirects when the blocked recipient is in cc rather than to" do
        mail = described_class.test_email_to_with_cc("seller@gmail.com", "boss@web.de").message

        expect(mail.delivery_method.settings[:address]).to eq(SENDGRID_SMTP_ADDRESS)
        expect(mail.header[MailerInfo.header_name(:email_provider)].value).to eq(MailerInfo::EMAIL_PROVIDER_SENDGRID)
      end

      it "leaves a message alone when neither the to nor the cc recipient is blocked" do
        mail = described_class.test_email_to_with_cc("seller@gmail.com", "boss@gmail.com").message

        expect(mail.delivery_method.settings[:address]).to eq(RESEND_SMTP_ADDRESS)
      end

      it "redirects when the blocked recipient is in bcc" do
        mail = described_class.test_email_to_with_bcc("seller@gmail.com", "archive@gmx.de").message

        expect(mail.delivery_method.settings[:address]).to eq(SENDGRID_SMTP_ADDRESS)
      end

      it "leaves other recipients on the provider the Router chose" do
        mail = described_class.test_email_to("buyer@gmail.com").message

        expect(mail.delivery_method.settings[:address]).to eq(RESEND_SMTP_ADDRESS)
        expect(mail.header[MailerInfo.header_name(:email_provider)].value).to eq(MailerInfo::EMAIL_PROVIDER_RESEND)
      end

      it "preserves the level_2 credential when swapping a level_2 seller's message" do
        # Every credential in the test environment is the same placeholder with a nil
        # password, so against the real EMAIL_CREDENTIALS a level_1 answer and a level_2
        # answer are indistinguishable and this assertion could not fail. Stub in a
        # credential set whose levels actually differ, so the level-preserving branch is
        # what's being tested rather than the shape of the return value.
        stub_const("EMAIL_CREDENTIALS", {
                     MailerInfo::EMAIL_PROVIDER_RESEND => {
                       customers: {
                         address: RESEND_SMTP_ADDRESS, username: "resend", password: "resend-l1",
                         domain: "customers.example.com",
                         levels: {
                           level_1: { username: "resend", password: "resend-l1", domain: "customers.example.com" },
                           level_2: { username: "resend", password: "resend-l2", domain: "customers.example.com" },
                         },
                       },
                     },
                     MailerInfo::EMAIL_PROVIDER_SENDGRID => {
                       customers: {
                         address: SENDGRID_SMTP_ADDRESS, username: "apikey", password: "sg-l1",
                         domain: "customers.example.com",
                         levels: {
                           level_1: { username: "apikey", password: "sg-l1", domain: "customers.example.com" },
                           level_2: { username: "apikey", password: "sg-l2", domain: "customers.example.com" },
                         },
                       },
                     },
                   })

        level_2_resend = {
          address: RESEND_SMTP_ADDRESS,
          domain: "customers.example.com",
          user_name: "resend",
          password: "resend-l2",
        }

        swapped = MailerInfo::DeliveryMethod.sendgrid_equivalent_options(level_2_resend)

        expect(swapped[:password]).to eq("sg-l2")
        expect(swapped[:address]).to eq(SENDGRID_SMTP_ADDRESS)
      end

      it "uses the level_1 credential when swapping a message that was not a level_2 seller's" do
        stub_const("EMAIL_CREDENTIALS", {
                     MailerInfo::EMAIL_PROVIDER_RESEND => {
                       customers: {
                         address: RESEND_SMTP_ADDRESS, username: "resend", password: "resend-l1",
                         domain: "customers.example.com",
                         levels: {
                           level_1: { username: "resend", password: "resend-l1", domain: "customers.example.com" },
                           level_2: { username: "resend", password: "resend-l2", domain: "customers.example.com" },
                         },
                       },
                     },
                     MailerInfo::EMAIL_PROVIDER_SENDGRID => {
                       customers: {
                         address: SENDGRID_SMTP_ADDRESS, username: "apikey", password: "sg-l1",
                         domain: "customers.example.com",
                         levels: {
                           level_1: { username: "apikey", password: "sg-l1", domain: "customers.example.com" },
                           level_2: { username: "apikey", password: "sg-l2", domain: "customers.example.com" },
                         },
                       },
                     },
                   })

        swapped = MailerInfo::DeliveryMethod.sendgrid_equivalent_options(
          address: RESEND_SMTP_ADDRESS, domain: "customers.example.com", user_name: "resend", password: "resend-l1"
        )

        expect(swapped[:password]).to eq("sg-l1")
      end

      it "leaves a message alone when its settings are already SendGrid" do
        expect(MailerInfo::DeliveryMethod.sendgrid_equivalent_options(sendgrid_options)).to be_nil
      end

      it "leaves a message alone when its settings match no known credential set" do
        expect(MailerInfo::DeliveryMethod.sendgrid_equivalent_options(nil)).to be_nil
        expect(MailerInfo::DeliveryMethod.sendgrid_equivalent_options({})).to be_nil
        expect(
          MailerInfo::DeliveryMethod.sendgrid_equivalent_options(address: RESEND_SMTP_ADDRESS, domain: "unknown.example.com")
        ).to be_nil
      end
    end
  end
end
