# frozen_string_literal: true

require "spec_helper"

describe OneOffMailer do
  let(:email) { "seller@example.com" }
  let(:reply_to) { ApplicationMailer::NOREPLY_EMAIL_WITH_NAME }

  describe "#email" do
    let(:subject) { "Email subject" }
    let(:body) { "Email body" }

    it "doesn't send attempt to email if both email and id are not provided" do
      mail = described_class.email(subject:, body:)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "doesn't send email if user has been marked as deleted" do
      deleted_user = create(:user, :deleted)
      mail = described_class.email(user_id: deleted_user.id, subject:, body:)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "doesn't send email if user is suspended" do
      suspended_user = create(:tos_user)
      mail = described_class.email(user_id: suspended_user.id, subject:, body:)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "doesn't send email if email address provided is invalid" do
      mail = described_class.email(email: "notvalid", subject:, body:)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "sets correct attributes" do
      mail = described_class.email(email:, subject:, body:)
      expect(mail.from).to include("hi@#{CUSTOMERS_MAIL_DOMAIN}")
      expect(mail.subject).to eq(subject)
      expect(mail.body.encoded).to include(body)
      expect(mail.reply_to).to be(nil)
    end

    it "allows safe html tags and strips unsafe ones" do
      mail = described_class.email(email:, subject:, body: "<a href=\"http://example.com\">link</a><script>alert('hello')</script>")
      expect(mail.body.encoded).to include("<a href=\"http://example.com\">link</a>")
      expect(mail.body.encoded).not_to include("<script>")
    end

    it "sets reply_to header if provided" do
      mail = described_class.email(email:, subject:, body:, reply_to:)
      expect(mail.reply_to).to include(ApplicationMailer::NOREPLY_EMAIL)

      mail = described_class.email(email:, subject:, body:)
      expect(mail.reply_to).to be(nil)
    end
  end

  describe "#email_using_installment" do
    let(:installment) { create(:installment, name: "My first installment", allow_comments: false) }
    let(:installment_external_id) { installment.external_id }

    it "doesn't send the email if neither recipient user ID nor recipient email is provided" do
      mail = described_class.email_using_installment(subject:, installment_external_id:)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "doesn't send the email if the recipient user has been marked as deleted" do
      deleted_user = create(:user, :deleted)
      mail = described_class.email_using_installment(user_id: deleted_user.id, installment_external_id:)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "doesn't send the email if the recipient user is suspended" do
      suspended_user = create(:tos_user)
      mail = described_class.email_using_installment(user_id: suspended_user.id, installment_external_id:)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "doesn't send the email if the provided recipient email address is invalid" do
      mail = described_class.email_using_installment(email: "notvalid", installment_external_id:)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "uses the provided installment's name to set the subject" do
      mail = described_class.email_using_installment(email:, installment_external_id:)
      expect(mail.subject).to eq("My first installment")
    end

    it "allows overriding the subject" do
      subject = "Another subject"
      mail = described_class.email_using_installment(email:, installment_external_id:, subject:)
      expect(mail.subject).to eq(subject)
    end

    it "generates the email body from the installment" do
      mail = described_class.email_using_installment(email:, installment_external_id:)
      expect(mail.body.encoded).to include(installment.message)
    end

    it "sets reply_to header if provided" do
      mail = described_class.email_using_installment(email:, subject:, installment_external_id:, reply_to:)
      expect(mail.reply_to).to include(ApplicationMailer::NOREPLY_EMAIL)

      mail = described_class.email(email:, subject:, body:)
      expect(mail.reply_to).to be(nil)
    end

    it "does not show the unsubscribe link" do
      mail = described_class.email_using_installment(email:, installment_external_id:)
      expect(mail.body.encoded).not_to include("Unsubscribe")
    end
  end
end
