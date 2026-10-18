# frozen_string_literal: true

require "spec_helper"

describe BlockedUsernameValidator do
  describe ".blocked?" do
    %w[go88tv go88sgpage bk8 sv88vip hi88 sunwin789 onlinecasino99 togelhk slotgacor77 jeetwin 488bet mobilbahis88bet nohu90].each do |name|
      it "blocks the gambling username #{name}" do
        expect(described_class.blocked?(name)).to be(true)
      end
    end

    %w[apple paypal paypalsupport nikeofficial bt btbroadband eebroadband amazon123 theapple].each do |name|
      it "blocks the brand username #{name} without a brand email" do
        expect(described_class.blocked?(name, email: "someone@gmail.com")).to be(true)
        expect(described_class.blocked?(name)).to be(true)
      end
    end

    it "allows a brand username when the email is on the brand's domain" do
      expect(described_class.blocked?("nike", email: "jane@nike.com")).to be(false)
      expect(described_class.blocked?("nikeofficial", email: "jane@mail.nike.com")).to be(false)
    end

    it "does not accept a lookalike domain" do
      expect(described_class.blocked?("nike", email: "jane@nike.com.evil.io")).to be(true)
      expect(described_class.blocked?("nike", email: "jane@notnike.com")).to be(true)
    end

    %w[johndoe casinostrategy pokercoach startups k12teacher designer88 applepie nikolai bettyspaghetti bt2 shelly sunrise].each do |name|
      it "allows the ordinary username #{name}" do
        expect(described_class.blocked?(name, email: "someone@gmail.com")).to be(false)
      end
    end
  end

  describe ".blocked_for?" do
    it "ignores an unconfirmed address, so the brand name stays blocked" do
      expect(described_class.blocked_for?("paypal", build(:unconfirmed_user, email: "x@paypal.com"))).to be(true)
      expect(described_class.blocked_for?("nikeofficial", build(:unconfirmed_user, email: "jane@nike.com"))).to be(true)
    end

    it "honours a confirmed address" do
      expect(described_class.blocked_for?("paypal", build(:user, email: "x@paypal.com"))).to be(false)
    end

    it "blocks gambling names even for a confirmed brand address" do
      expect(described_class.blocked_for?("sunwin789", build(:user, email: "x@paypal.com"))).to be(true)
    end

    it "treats a record that cannot confirm an address as unproven" do
      expect(described_class.blocked_for?("paypal", Struct.new(:email).new("x@paypal.com"))).to be(true)
    end
  end

  describe "on User" do
    it "rejects a blocked username with a message that says who to email" do
      user = build(:user, username: "go88tv")
      expect(user).not_to be_valid
      expect(user.errors[:username].first).to include("support@gumroad.com")
    end

    it "rejects a brand username for a non-brand email" do
      expect(build(:user, username: "paypalsupport", email: "x@gmail.com")).not_to be_valid
    end

    it "accepts a brand username for a confirmed brand email" do
      expect(build(:user, username: "paypal", email: "x@paypal.com")).to be_valid
    end

    it "rejects a brand username when the brand email is not confirmed" do
      user = build(:unconfirmed_user, username: "paypalsupport", email: "x@paypal.com")
      expect(user).not_to be_valid
      expect(user.errors[:username].first).to include("support@gumroad.com")
    end

    it "does not re-validate an existing blocked username when other fields change" do
      user = create(:user)
      user.update_column(:username, "go88tv")
      user.name = "New name"
      expect(user).to be_valid
    end
  end
end
