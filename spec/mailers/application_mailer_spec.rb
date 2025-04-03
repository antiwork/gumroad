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
  end
end
