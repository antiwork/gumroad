# frozen_string_literal: true

require "spec_helper"

describe InvisibleCharacterRecipientSanitizer do
  # Accounts created before we started refusing addresses that carry an invisible character still
  # hold one, and the mail provider rejects every message to such an address. Cleaning the
  # recipient at delivery time is what lets those accounts start receiving mail again without
  # waiting for the stored address to be corrected.
  def deliver_to(recipient)
    mail = Mail.new(from: "noreply@#{DEFAULT_EMAIL_DOMAIN}", subject: "Test", body: "Test")
    mail.to = recipient
    described_class.delivering_email(mail)
    mail
  end

  it "removes a leading right-to-left mark from the recipient" do
    expect(deliver_to("\u200Fbuyer@example.com").to).to eq ["buyer@example.com"]
  end

  it "removes the other invisible characters" do
    expect(deliver_to("buyer\u200Bx@example.com").to).to eq ["buyerx@example.com"]
    expect(deliver_to("\uFEFFbuyer@example.com").to).to eq ["buyer@example.com"]
    expect(deliver_to("buyer\u00A0@example.com").to).to eq ["buyer@example.com"]
  end

  it "cleans every recipient when there are several" do
    mail = deliver_to(["\u200Fone@example.com", "two@example.com"])

    expect(mail.to).to eq ["one@example.com", "two@example.com"]
  end

  it "cleans cc and bcc as well as to" do
    mail = Mail.new(from: "noreply@#{DEFAULT_EMAIL_DOMAIN}", subject: "Test", body: "Test")
    mail.to = "buyer@example.com"
    mail.cc = "\u200Fcopy@example.com"
    mail.bcc = "\u200Fblind@example.com"

    described_class.delivering_email(mail)

    expect(mail.cc).to eq ["copy@example.com"]
    expect(mail.bcc).to eq ["blind@example.com"]
  end

  it "leaves an ordinary recipient untouched" do
    expect(deliver_to("buyer@example.com").to).to eq ["buyer@example.com"]
  end

  it "does nothing when there is no recipient to clean" do
    mail = Mail.new(from: "noreply@#{DEFAULT_EMAIL_DOMAIN}", subject: "Test", body: "Test")

    expect { described_class.delivering_email(mail) }.not_to raise_error
    expect(mail.to).to be_nil
  end

  # The stored record is deliberately left alone: repairing the row is a separate auditable
  # backfill, and a delivery-time hook is the wrong place to write to the database.
  it "does not modify the stored record" do
    user = create(:user)
    user.update_column(:email, "\u200Fbuyer@example.com")

    deliver_to(user.email)

    expect(user.reload.email).to eq "\u200Fbuyer@example.com"
  end
end
