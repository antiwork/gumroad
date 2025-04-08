# frozen_string_literal: true

require "spec_helper"

describe PostEmailApi do
  let(:seller) { create(:named_user) }
  let(:post) { create(:audience_installment, seller: seller) }
  let(:recipients) do
    10.times.map { |i| { email: "recipient#{i}@gumroad-example.com" } }
  end
  let(:args) { { post: post, recipients: recipients } }

  describe ".process" do
    context "when the feature flag is active" do
      before do
        allow(Feature).to receive(:inactive?).with(:use_resend_for_post_emails, seller).and_return(false)

        # Email via Resend for the first 4 recipients, SendGrid for the rest
        allow(MailerInfo::Router).to receive(:determine_email_provider) do |domain|
          @call_count ||= 0
          @call_count += 1
          @call_count <= 4 ? MailerInfo::EMAIL_PROVIDER_RESEND : MailerInfo::EMAIL_PROVIDER_SENDGRID
        end
      end

      it "splits recipients between Resend and SendGrid" do
        resend_recipients = recipients[0..3]
        sendgrid_recipients = recipients[4..9]

        expect(PostResendApi).to receive(:process).with(args.merge(recipients: resend_recipients))
        expect(PostSendgridApi).to receive(:process).with(args.merge(recipients: sendgrid_recipients))

        PostEmailApi.process(**args)
      end

      it "routes non-ASCII emails through SendGrid" do
        # Set to resend to test the fallback
        allow(MailerInfo::Router).to receive(:determine_email_provider).and_return(MailerInfo::EMAIL_PROVIDER_RESEND)

        non_ascii_recipients = [{ email: "récipient@gumroad-example.com" }]
        non_ascii_args = { post: post, recipients: non_ascii_recipients }

        expect(PostSendgridApi).to receive(:process).with(non_ascii_args)
        expect(PostResendApi).not_to receive(:process)

        PostEmailApi.process(**non_ascii_args)
      end

      it "routes emails with local parts exceeding 64 characters through SendGrid" do
        # Set to resend to test the fallback
        allow(MailerInfo::Router).to receive(:determine_email_provider).and_return(MailerInfo::EMAIL_PROVIDER_RESEND)

        # Create an email with local part longer than 64 characters
        long_local_part = "a" * 65 # 65 characters
        long_email_recipient = [{ email: "#{long_local_part}@gumroad-example.com" }]
        long_email_args = { post: post, recipients: long_email_recipient }

        expect(PostSendgridApi).to receive(:process).with(long_email_args)
        expect(PostResendApi).not_to receive(:process)

        PostEmailApi.process(**long_email_args)
      end

      it "routes emails with special characters through SendGrid" do
        # Set to resend to test the fallback
        allow(MailerInfo::Router).to receive(:determine_email_provider).and_return(MailerInfo::EMAIL_PROVIDER_RESEND)

        # Test with various special characters that should be rejected by the regex
        special_char_emails = [
          { email: "recipient!@gumroad-example.com" },   # exclamation mark
          { email: "recipient*@gumroad-example.com" },   # asterisk
          { email: "recipient=@gumroad-example.com" },   # equals sign
          { email: "recipient$@gumroad-example.com" },   # dollar sign
          { email: "recipient{@gumroad-example.com" },   # curly brace
          { email: "recipient-name@gumroad-example.com" } # hyphen
        ]

        special_char_emails.each do |email_recipient|
          special_char_args = { post: post, recipients: [email_recipient] }

          expect(PostSendgridApi).to receive(:process).with(special_char_args)
          expect(PostResendApi).not_to receive(:process)

          PostEmailApi.process(**special_char_args)
        end
      end

      it "routes emails with formatting issues through SendGrid" do
        # Set to resend to test the fallback
        allow(MailerInfo::Router).to receive(:determine_email_provider).and_return(MailerInfo::EMAIL_PROVIDER_RESEND)

        # Test various email formatting issues
        invalid_format_emails = [
          { email: "" },                           # blank email
          { email: nil },                          # nil email
          { email: "userexample.com" },            # missing @ symbol
          { email: "user@example@domain.com" },    # multiple @ symbols
          { email: "@gumroad-example.com" },               # blank local part
          { email: "user@" },                      # blank domain part
          { email: "user@gumroad-example" },               # domain without period
          { email: "user@.gumroad-example.com" },          # domain starting with period
          { email: "user@gumroad-example.com." }           # domain ending with period
        ]

        invalid_format_emails.each do |email_recipient|
          invalid_format_args = { post: post, recipients: [email_recipient] }

          expect(PostSendgridApi).to receive(:process).with(invalid_format_args)
          expect(PostResendApi).not_to receive(:process)

          PostEmailApi.process(**invalid_format_args)
        end
      end

      it "routes emails from excluded domains through SendGrid" do
        # Set to resend to test the fallback
        allow(MailerInfo::Router).to receive(:determine_email_provider).and_return(MailerInfo::EMAIL_PROVIDER_RESEND)

        # Test with emails from excluded domains
        excluded_domains = ["example.com", "example.org", "example.net", "test.com"]
        excluded_domain_emails = excluded_domains.map do |domain|
          { email: "user@#{domain}" }
        end

        excluded_domain_emails.each do |email_recipient|
          excluded_domain_args = { post: post, recipients: [email_recipient] }

          expect(PostSendgridApi).to receive(:process).with(excluded_domain_args)
          expect(PostResendApi).not_to receive(:process)

          PostEmailApi.process(**excluded_domain_args)
        end
      end

      it "routes emails exceeding maximum length through SendGrid" do
        # Set to resend to test the fallback
        allow(MailerInfo::Router).to receive(:determine_email_provider).and_return(MailerInfo::EMAIL_PROVIDER_RESEND)

        # Test email with total length exceeding 254 characters
        long_domain = "gumroad-example.com"
        long_local_part = "a" * 245  # Makes total email length > 254 characters
        long_email_args = { post: post, recipients: [{ email: "#{long_local_part}@#{long_domain}" }] }

        expect(PostSendgridApi).to receive(:process).with(long_email_args)
        expect(PostResendApi).not_to receive(:process)

        PostEmailApi.process(**long_email_args)
      end

      it "routes valid emails through Resend when determined by the router" do
        # Valid email with only permitted special characters
        valid_recipient = { email: "user.name+tag@gumroad-example.com" }
        valid_args = { post: post, recipients: [valid_recipient] }

        # Configure router to choose Resend
        allow(MailerInfo::Router).to receive(:determine_email_provider)
          .with(MailerInfo::DeliveryMethod::DOMAIN_CREATORS)
          .and_return(MailerInfo::EMAIL_PROVIDER_RESEND)

        expect(PostResendApi).to receive(:process).with(valid_args)
        expect(PostSendgridApi).not_to receive(:process)

        PostEmailApi.process(**valid_args)
      end

      it "routes valid emails through SendGrid when determined by the router" do
        # Valid email with only permitted special characters
        valid_recipient = { email: "user_name_123@gumroad-example.com" }
        valid_args = { post: post, recipients: [valid_recipient] }

        # Configure router to choose SendGrid
        allow(MailerInfo::Router).to receive(:determine_email_provider)
          .with(MailerInfo::DeliveryMethod::DOMAIN_CREATORS)
          .and_return(MailerInfo::EMAIL_PROVIDER_SENDGRID)

        expect(PostSendgridApi).to receive(:process).with(valid_args)
        expect(PostResendApi).not_to receive(:process)

        PostEmailApi.process(**valid_args)
      end
    end

    context "when the feature flag is inactive" do
      before do
        allow(Feature).to receive(:inactive?).with(:use_resend_for_post_emails, seller).and_return(true)
      end

      it "sends all emails through SendGrid" do
        expect(PostSendgridApi).to receive(:process).with(args)
        PostEmailApi.process(**args)
      end
    end
  end

  describe ".max_recipients" do
    context "when the feature flag is active" do
      it "returns the Resend max recipients" do
        allow(Feature).to receive(:active?).with(:use_resend_for_post_emails).and_return(true)
        expect(PostEmailApi.max_recipients).to eq(PostResendApi::MAX_RECIPIENTS)
      end
    end

    context "when the feature flag is inactive" do
      it "returns the SendGrid max recipients" do
        allow(Feature).to receive(:active?).with(:use_resend_for_post_emails).and_return(false)
        expect(PostEmailApi.max_recipients).to eq(PostSendgridApi::MAX_RECIPIENTS)
      end
    end
  end
end
