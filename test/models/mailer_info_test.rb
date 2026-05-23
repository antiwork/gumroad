# frozen_string_literal: true

require "test_helper"

class MailerInfoTest < ActiveSupport::TestCase
  self.described_class = MailerInfo



  context_ MailerInfo do
  context_ ".header_name" do
  test "formats valid header names" do
        expect(described_class.header_name(:email_provider)).to eq("X-GUM-Email-Provider")
        expect(described_class.header_name(:mailer_class)).to eq("X-GUM-Mailer-Class")
      end

  test "raises error for invalid header names" do
        expect { described_class.header_name(:invalid) }.to raise_error(ArgumentError, /Invalid header field/)
      end
    end

  context_ ".encrypt" do
  test "delegates to Encryption" do
        allow(MailerInfo::Encryption).to receive(:encrypt).with("test").and_return("encrypted")
        expect(described_class.encrypt("test")).to eq("encrypted")
      end
    end

  context_ ".decrypt" do
  test "delegates to Encryption" do
        allow(MailerInfo::Encryption).to receive(:decrypt).with("encrypted").and_return("test")
        expect(described_class.decrypt("encrypted")).to eq("test")
      end
    end

  context_ ".parse_resend_webhook_header" do
      let(:headers) do
        [
          { "name" => "X-GUM-Environment", "value" => "encrypted_env" },
          { "name" => "X-GUM-Mailer-Class", "value" => "encrypted_class" }
        ]
      end

  test "finds and decrypts header value" do
        allow(described_class).to receive(:decrypt).with("encrypted_class").and_return("TestMailer")
        expect(described_class.parse_resend_webhook_header(headers, :mailer_class)).to eq("TestMailer")
      end

  test "returns nil for missing header" do
        expect(described_class.parse_resend_webhook_header(headers, :workflow_ids)).to be_nil
      end

  test "returns nil for nil headers" do
        expect(described_class.parse_resend_webhook_header(nil, :mailer_class)).to be_nil
      end
    end

  context_ ".random_email_provider" do
  test "delegates to Router" do
        allow(MailerInfo::Router).to receive(:determine_email_provider).with(:gumroad).and_return("sendgrid")
        expect(described_class.random_email_provider(:gumroad)).to eq("sendgrid")
      end
    end

  context_ ".random_delivery_method_options" do
      let(:domain) { :gumroad }
      let(:seller) { nil }

  test "gets provider from Router and delegates to DeliveryMethod" do
        allow(described_class).to receive(:random_email_provider).with(domain).and_return("sendgrid")
        allow(MailerInfo::DeliveryMethod).to receive(:options).with(
          domain: domain,
          email_provider: "sendgrid",
          seller: seller
        ).and_return({ address: "smtp.sendgrid.net" })

        expect(described_class.random_delivery_method_options(domain:, seller:)).to eq({ address: "smtp.sendgrid.net" })
      end
    end

  context_ ".default_delivery_method_options" do
  test "uses SendGrid as provider" do
        allow(MailerInfo::DeliveryMethod).to receive(:options).with(
          domain: :gumroad,
          email_provider: MailerInfo::EMAIL_PROVIDER_SENDGRID
        ).and_return({ address: "smtp.sendgrid.net" })

        expect(described_class.default_delivery_method_options(domain: :gumroad)).to eq({ address: "smtp.sendgrid.net" })
      end
    end
  end
end
