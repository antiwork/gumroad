# frozen_string_literal: true

require "test_helper"

class UserEmailNormalizationTest < ActiveSupport::TestCase
  self.described_class = User::EmailNormalization



  context_ User::EmailNormalization do
  context_ ".normalize_gmail_address" do
  test "strips plus-addressing from Gmail addresses" do
        expect(User.normalize_gmail_address("user+suffix@gmail.com")).to eq("user@gmail.com")
      end

  test "removes dots from Gmail local parts" do
        expect(User.normalize_gmail_address("u.s.e.r@gmail.com")).to eq("user@gmail.com")
      end

  test "handles both plus-addressing and dots together" do
        expect(User.normalize_gmail_address("u.s.e.r+suffix@gmail.com")).to eq("user@gmail.com")
      end

  test "normalizes googlemail.com to gmail.com" do
        expect(User.normalize_gmail_address("user+test@googlemail.com")).to eq("user@gmail.com")
      end

  test "downcases the email" do
        expect(User.normalize_gmail_address("User+Test@Gmail.com")).to eq("user@gmail.com")
      end

  test "returns the original email downcased for non-Gmail domains" do
        expect(User.normalize_gmail_address("user+test@example.com")).to eq("user+test@example.com")
      end

  test "returns nil for blank input" do
        expect(User.normalize_gmail_address("")).to be_nil
        expect(User.normalize_gmail_address(nil)).to be_nil
      end
    end

  context_ ".abusive_gmail_variant_exists?" do
  context_ "when the normalized email is in the Redis set" do
        before { GmailAbuseFilter.add!("abuser@gmail.com") }
        after { $redis.del(GmailAbuseFilter::REDIS_KEY) }

  test "detects plus-addressed variants" do
          expect(User.abusive_gmail_variant_exists?("abuser+random123@gmail.com")).to be(true)
        end

  test "detects dot variants" do
          expect(User.abusive_gmail_variant_exists?("a.b.u.s.e.r@gmail.com")).to be(true)
        end

  test "detects combined plus and dot variants" do
          expect(User.abusive_gmail_variant_exists?("a.b.u.s.e.r+test@gmail.com")).to be(true)
        end
      end

  context_ "when the normalized email is not in the Redis set" do
  test "returns false" do
          expect(User.abusive_gmail_variant_exists?("gooduser+test@gmail.com")).to be(false)
        end
      end

  context_ "with non-Gmail addresses" do
  test "returns false" do
          expect(User.abusive_gmail_variant_exists?("abuser+test@example.com")).to be(false)
        end
      end
    end

  context_ "email_not_from_suspended_gmail_variant validation" do
      before { Feature.activate(:block_gmail_abuse_at_signup) }
      after do
        Feature.deactivate(:block_gmail_abuse_at_signup)
        $redis.del(GmailAbuseFilter::REDIS_KEY)
      end

  context_ "when a suspended account's normalized email is in the filter" do
        before { GmailAbuseFilter.add!("scammer@gmail.com") }

  test "blocks signup with a plus-addressed variant" do
          user = build(:user, email: "scammer+new@gmail.com")
          user.valid?(:create)
          expect(user.errors[:base]).to include("Something went wrong.")
        end

  test "blocks signup with a dot variant" do
          user = build(:user, email: "s.c.a.m.m.e.r@gmail.com")
          user.valid?(:create)
          expect(user.errors[:base]).to include("Something went wrong.")
        end
      end

  context_ "when no matching email is in the filter" do
  test "allows signup" do
          user = build(:user, email: "newuser+tag@gmail.com")
          user.valid?(:create)
          expect(user.errors[:base]).to be_empty
        end
      end

  context_ "when the feature flag is disabled" do
        before do
          Feature.deactivate(:block_gmail_abuse_at_signup)
          GmailAbuseFilter.add!("scammer@gmail.com")
        end

  test "skips the validation" do
          user = build(:user, email: "scammer+new@gmail.com")
          user.valid?(:create)
          expect(user.errors[:base]).to be_empty
        end
      end
    end
  end
end
