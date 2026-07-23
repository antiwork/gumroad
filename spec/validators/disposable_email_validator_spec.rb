# frozen_string_literal: true

require "spec_helper"

describe DisposableEmailValidator do
  describe ".disposable?" do
    it "returns true for known disposable domains" do
      expect(DisposableEmailValidator.disposable?("test@mailinator.com")).to be(true)
      expect(DisposableEmailValidator.disposable?("test@guerrillamail.com")).to be(true)
    end

    it "returns false for legitimate domains" do
      expect(DisposableEmailValidator.disposable?("test@gmail.com")).to be(false)
      expect(DisposableEmailValidator.disposable?("test@example.com")).to be(false)
    end

    it "returns false for blank input" do
      expect(DisposableEmailValidator.disposable?("")).to be(false)
      expect(DisposableEmailValidator.disposable?(nil)).to be(false)
    end

    it "is case-insensitive" do
      expect(DisposableEmailValidator.disposable?("test@MAILINATOR.COM")).to be(true)
    end
  end

  describe "user signup validation" do
    it "blocks signup with a disposable email domain" do
      user = build(:user, email: "test@mailinator.com")
      user.valid?(:create)
      expect(user.errors[:email]).to include("is from a disposable email provider and cannot be used")
    end

    it "allows signup with a legitimate email domain" do
      user = build(:user, email: "test@example.com")
      user.valid?(:create)
      expect(user.errors[:email]).to be_empty
    end

    it "does not re-validate existing users on update" do
      user = create(:user)
      user.update_column(:email, "test@mailinator.com")
      user.name = "New Name"
      expect(user.valid?).to be(true)
    end
  end
end
