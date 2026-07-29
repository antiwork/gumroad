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

  # Cleaning the recipient is only safe while the cleaned address belongs to the same person. Two
  # live accounts can hold the two variants of the same-looking address — one signed up before we
  # started refusing hidden characters, the other after — and rewriting the recipient there would
  # take a message addressed to the first account (a reset link, a login code, a receipt with
  # download links) and deliver it into the second account's mailbox, letting its owner take over
  # the first account. The message is left addressed as it was instead, so it bounces exactly as
  # it did before this interceptor existed.
  describe "when the cleaned address belongs to a different account" do
    # Both rows are written with update_column, which is the only way this pair can exist. Signup
    # itself cannot produce it: User's own uniqueness check is `User.by_email(email)`, and because
    # the email column collates as utf8mb4_unicode_ci that query matches across the invisible
    # character, so whichever variant is submitted second is refused as "An account already exists
    # with this email." The pair can still arrive from a path that writes the column directly — a
    # data migration, an admin correction, a save that skips validation — and the cost of being
    # wrong is an account takeover, so the interceptor checks rather than assuming.
    def stored_as(address)
      create(:user).tap { _1.update_column(:email, address) }
    end

    it "leaves the recipient alone rather than delivering to the other mailbox" do
      legacy = stored_as("\u200Fbuyer@example.com")
      other = stored_as("buyer@example.com")

      expect(deliver_to(legacy.email).to).to eq ["\u200Fbuyer@example.com"]
      expect(other.reload.email).to eq "buyer@example.com"
    end

    it "leaves the recipient alone when the other account stores a case variant of the cleaned address" do
      legacy = stored_as("\u200Fbuyer@example.com")
      other = stored_as("Buyer@example.com")

      expect(deliver_to(legacy.email).to).to eq ["\u200Fbuyer@example.com"]
      expect(other.reload.email).to eq "Buyer@example.com"
    end

    it "leaves the recipient alone when the other account stores another invisible-character variant" do
      legacy = stored_as("\u200Fbuyer@example.com")
      other = stored_as("\uFEFFbuyer@example.com")

      expect(deliver_to(legacy.email).to).to eq ["\u200Fbuyer@example.com"]
      expect(other.reload.email).to eq "\uFEFFbuyer@example.com"
    end

    it "still cleans the other recipients in the same message" do
      legacy = stored_as("\u200Fbuyer@example.com")
      stored_as("buyer@example.com")

      mail = deliver_to([legacy.email, "\u200Fsomeone-else@example.com"])

      expect(mail.to).to eq ["\u200Fbuyer@example.com", "someone-else@example.com"]
    end

    it "cleans it when the same account owns both variants" do
      user = stored_as("\u200Fbuyer@example.com")

      expect(deliver_to(user.email).to).to eq ["buyer@example.com"]
    end

    # Delivery goes to the external mailbox, not to a Gumroad account. A deleted Gumroad account
    # that once owned the cleaned address still proves somebody else may receive that mailbox, so
    # the sanitizer must fail closed rather than rewrite a dirty account's reset link there.
    it "leaves it alone when the account owning the cleaned form is deleted" do
      legacy = stored_as("\u200Fbuyer@example.com")
      stored_as("buyer@example.com").mark_deleted!

      expect(deliver_to(legacy.email).to).to eq ["\u200Fbuyer@example.com"]
    end
  end

  # The examples above call the interceptor directly, which proves the logic but not that Rails
  # actually runs it. This one goes through a real delivery so a future change that drops the
  # registration in config/initializers/mail_observers.rb fails here rather than silently
  # returning us to bouncing every message to these accounts.
  describe "registration" do
    it "is registered as an ActionMailer delivery interceptor" do
      registered = Mail.class_variable_get(:@@delivery_interceptors).flatten.map(&:to_s)

      expect(registered).to include(described_class.to_s)
    end

    it "cleans the recipient on a message delivered through ActionMailer" do
      expect do
        ActionMailer::Base.mail(
          to: "\u200Fbuyer@example.com",
          from: "noreply@#{DEFAULT_EMAIL_DOMAIN}",
          subject: "Test",
          body: "Test"
        ).deliver_now
      end.to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(ActionMailer::Base.deliveries.last.to).to eq ["buyer@example.com"]
    end
  end
end
