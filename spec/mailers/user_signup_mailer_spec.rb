# frozen_string_literal: true

require "spec_helper"

describe UserSignupMailer do
  it "includes RescueSmtpErrors" do
    expect(described_class).to include(RescueSmtpErrors)
  end

  describe "#confirmation_instructions" do
    before do
      user = create(:user)
      @mail = described_class.confirmation_instructions(user, {})
    end

    it "sets the correct headers" do
      expect(@mail.subject).to eq "Confirmation instructions"
      expect(@mail.from).to eq [ApplicationMailer::NOREPLY_EMAIL]
      expect(@mail.reply_to).to eq [ApplicationMailer::NOREPLY_EMAIL]
    end

    it "includes the notification message" do
      expect(@mail.body).to include("Confirm your email address")
      expect(@mail.body).to include("Please confirm your account by clicking the button below.")
      expect(@mail.body).to include("If you didn't request this, please ignore this email. You won't get another one!")
    end
  end

  describe "#email_changed" do
    before do
      @user = create(:user, email: "original@example.com", unconfirmed_email: "new@example.com")
      @mail = described_class.email_changed(@user)
    end

    it "sets the correct headers" do
      expect(@mail.subject).to eq "Security alert: Your Gumroad account email is being changed"
      expect(@mail.from).to eq [ApplicationMailer::NOREPLY_EMAIL]
      expect(@mail.reply_to).to eq [ApplicationMailer::NOREPLY_EMAIL]
    end

    it "includes the notification message" do
      expect(@mail.body).to include("Your Gumroad account email is being changed")
      expect(@mail.body).to include("We're contacting you to notify that your Gumroad account email is being changed from original@example.com to new@example.com.")
      expect(@mail.body).to include("If you did not make this change, please contact support immediately by replying to this email.")
      expect(@mail.body).to include("User ID: #{@user.external_id}")
    end
  end

  describe "#reset_password_instructions" do
    before do
      user = create(:user)
      @mail = described_class.reset_password_instructions(user, {})
    end

    it "sets the correct headers" do
      expect(@mail.subject).to eq "Reset password instructions"
      expect(@mail.from).to eq [ApplicationMailer::NOREPLY_EMAIL]
      expect(@mail.reply_to).to eq [ApplicationMailer::NOREPLY_EMAIL]
    end

    it "includes the notification message" do
      expect(@mail.body).to include("Forgotten password request")
      expect(@mail.body).to include("It seems you forgot the password for your Gumroad account. You can change your password by clicking the button below:")
      expect(@mail.body).to include("If you didn't request this, please ignore this email. You won't get another one!")
    end
  end
end
