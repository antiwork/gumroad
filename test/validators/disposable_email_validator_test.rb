# frozen_string_literal: true

require "test_helper"

class DisposableEmailValidatorTest < ActiveSupport::TestCase
  self.described_class = DisposableEmailValidator



  context_ DisposableEmailValidator do
  context_ ".disposable?" do
  test "returns true for known disposable domains" do
        expect(DisposableEmailValidator.disposable?("test@mailinator.com")).to be(true)
        expect(DisposableEmailValidator.disposable?("test@guerrillamail.com")).to be(true)
      end

  test "returns false for legitimate domains" do
        expect(DisposableEmailValidator.disposable?("test@gmail.com")).to be(false)
        expect(DisposableEmailValidator.disposable?("test@example.com")).to be(false)
      end

  test "returns false for blank input" do
        expect(DisposableEmailValidator.disposable?("")).to be(false)
        expect(DisposableEmailValidator.disposable?(nil)).to be(false)
      end

  test "is case-insensitive" do
        expect(DisposableEmailValidator.disposable?("test@MAILINATOR.COM")).to be(true)
      end
    end

  context_ "user signup validation" do
      before do
        Feature.activate(:block_disposable_emails_at_signup)
      end

      after do
        Feature.deactivate(:block_disposable_emails_at_signup)
      end

  test "blocks signup with a disposable email domain" do
        user = build(:user, email: "test@mailinator.com")
        user.valid?(:create)
        expect(user.errors[:email]).to include("is from a disposable email provider and cannot be used")
      end

  test "allows signup with a legitimate email domain" do
        user = build(:user, email: "test@example.com")
        user.valid?(:create)
        expect(user.errors[:email]).to be_empty
      end

  context_ "when the feature flag is disabled" do
        before { Feature.deactivate(:block_disposable_emails_at_signup) }

  test "skips the validation" do
          user = build(:user, email: "test@mailinator.com")
          user.valid?(:create)
          expect(user.errors[:email]).to be_empty
        end
      end
    end
  end
end
