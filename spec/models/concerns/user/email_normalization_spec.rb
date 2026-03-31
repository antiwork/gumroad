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
    context "when a suspended account exists with the normalized base email" do
      let!(:suspended_user) { create(:user, :suspended, email: "abuser@gmail.com") }

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

    context "when a suspended account exists with a plus-addressed email" do
      let!(:suspended_user) { create(:user, :suspended, email: "abuser+old@gmail.com") }

      it "detects new plus-addressed variants from the same base" do
        expect(User.abusive_gmail_variant_exists?("abuser+new@gmail.com")).to be(true)
      end
    end

    context "when a flagged account exists" do
      let!(:flagged_user) { create(:user, :flagged_for_tos_violation, email: "flagged@gmail.com") }

      it "detects variants of the flagged account" do
        expect(User.abusive_gmail_variant_exists?("flagged+test@gmail.com")).to be(true)
      end
    end

    context "when the existing account is compliant" do
      let!(:compliant_user) { create(:compliant_user, email: "gooduser@gmail.com") }

      it "returns false" do
        expect(User.abusive_gmail_variant_exists?("gooduser+test@gmail.com")).to be(false)
      end
    end

    context "with non-Gmail addresses" do
      let!(:suspended_user) { create(:user, :suspended, email: "abuser@example.com") }

      it "returns false" do
        expect(User.abusive_gmail_variant_exists?("abuser+test@example.com")).to be(false)
      end
    end
  end

  describe "email_not_from_suspended_gmail_variant validation" do
    before do
      Feature.activate(:block_gmail_abuse_at_signup)
    end

    after do
      Feature.deactivate(:block_gmail_abuse_at_signup)
    end

    context "when a suspended account exists with the same normalized Gmail address" do
      let!(:suspended_user) { create(:user, :suspended, email: "scammer@gmail.com") }

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

    context "when no suspended account exists" do
      it "allows signup" do
        user = build(:user, email: "newuser+tag@gmail.com")
        user.valid?(:create)
        expect(user.errors[:base]).to be_empty
      end
    end

    context "when the feature flag is disabled" do
      before { Feature.deactivate(:block_gmail_abuse_at_signup) }

      it "skips the validation" do
        create(:user, :suspended, email: "scammer@gmail.com")
        user = build(:user, email: "scammer+new@gmail.com")
        user.valid?(:create)
        expect(user.errors[:base]).to be_empty
      end
    end
  end
end
