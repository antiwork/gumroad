# frozen_string_literal: true

require "spec_helper"

describe User::EmailNormalization do
  describe ".normalize_gmail_address" do
    it "strips plus-addressing from Gmail addresses" do
      expect(User.normalize_gmail_address("user+suffix@gmail.com")).to eq("user@gmail.com")
    end

    it "removes dots from Gmail local parts" do
      expect(User.normalize_gmail_address("u.s.e.r@gmail.com")).to eq("user@gmail.com")
    end

    it "handles both plus-addressing and dots together" do
      expect(User.normalize_gmail_address("u.s.e.r+suffix@gmail.com")).to eq("user@gmail.com")
    end

    it "normalizes googlemail.com to gmail.com" do
      expect(User.normalize_gmail_address("user+test@googlemail.com")).to eq("user@gmail.com")
    end

    it "downcases the email" do
      expect(User.normalize_gmail_address("User+Test@Gmail.com")).to eq("user@gmail.com")
    end

    it "returns the original email downcased for non-Gmail domains" do
      expect(User.normalize_gmail_address("user+test@example.com")).to eq("user+test@example.com")
    end

    it "returns nil for blank input" do
      expect(User.normalize_gmail_address("")).to be_nil
      expect(User.normalize_gmail_address(nil)).to be_nil
    end
  end

  describe ".abusive_gmail_variant_exists?" do
    context "when the normalized email is in the Redis set" do
      before { GmailAbuseFilter.add!("abuser@gmail.com") }
      after { $redis.del(GmailAbuseFilter::REDIS_KEY) }

      it "detects plus-addressed variants" do
        expect(User.abusive_gmail_variant_exists?("abuser+random123@gmail.com")).to be(true)
      end

      it "detects dot variants" do
        expect(User.abusive_gmail_variant_exists?("a.b.u.s.e.r@gmail.com")).to be(true)
      end

      it "detects combined plus and dot variants" do
        expect(User.abusive_gmail_variant_exists?("a.b.u.s.e.r+test@gmail.com")).to be(true)
      end
    end

    context "when the normalized email is not in the Redis set" do
      it "returns false" do
        expect(User.abusive_gmail_variant_exists?("gooduser+test@gmail.com")).to be(false)
      end
    end

    context "with non-Gmail addresses" do
      it "returns false" do
        expect(User.abusive_gmail_variant_exists?("abuser+test@example.com")).to be(false)
      end
    end
  end

  describe "email_not_from_suspended_gmail_variant validation" do
    after { $redis.del(GmailAbuseFilter::REDIS_KEY) }

    context "when a suspended account's normalized email is in the filter" do
      before { GmailAbuseFilter.add!("scammer@gmail.com") }

      it "blocks signup with a plus-addressed variant" do
        user = build(:user, email: "scammer+new@gmail.com")
        user.valid?(:create)
        expect(user.errors[:base]).to include("Something went wrong.")
      end

      it "blocks signup with a dot variant" do
        user = build(:user, email: "s.c.a.m.m.e.r@gmail.com")
        user.valid?(:create)
        expect(user.errors[:base]).to include("Something went wrong.")
      end
    end

    context "when no matching email is in the filter" do
      it "allows signup" do
        user = build(:user, email: "newuser+tag@gmail.com")
        user.valid?(:create)
        expect(user.errors[:base]).to be_empty
      end
    end
  end

  describe ".blocked_signup_error?" do
    after { $redis.del(GmailAbuseFilter::REDIS_KEY) }

    it "returns true for a RecordInvalid raised by the gmail-abuse signup gate" do
      GmailAbuseFilter.add!("scammer@gmail.com")
      user = build(:user, email: "scammer+new@gmail.com")

      exception = begin
        user.save!
        nil
      rescue ActiveRecord::RecordInvalid => e
        e
      end

      expect(exception).to be_present
      expect(User.blocked_signup_error?(exception)).to be(true)
    end

    it "returns false for a RecordInvalid raised by an unrelated validation" do
      user = build(:user, email: "not-an-email")

      exception = begin
        user.save!
        nil
      rescue ActiveRecord::RecordInvalid => e
        e
      end

      expect(exception).to be_present
      expect(User.blocked_signup_error?(exception)).to be(false)
    end

    it "returns false for exceptions without a record" do
      expect(User.blocked_signup_error?(StandardError.new("boom"))).to be(false)
    end
  end
end
