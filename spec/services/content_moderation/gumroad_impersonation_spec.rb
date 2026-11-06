# frozen_string_literal: true

require "spec_helper"

describe ContentModeration::GumroadImpersonation do
  describe ".impersonates?" do
    [
      "Gumroad Security Team",
      "Gumroad Payout Verification",
      "GUMROAD Trust & Safety",
      "Ｇｕｍｒｏａｄ Security",
      "Gum-road Billing Alert",
      "Payouts @ Gumroad",
    ].each do |name|
      it "flags #{name.inspect}" do
        expect(described_class.impersonates?(name)).to be(true)
      end
    end

    [
      "How I made $10k on Gumroad",
      "Gumroad Sales Playbook",
      "Home Security Checklist",
      "Payout Tracker Spreadsheet",
      nil,
    ].each do |name|
      it "allows #{name.inspect}" do
        expect(described_class.impersonates?(name)).to be(false)
      end
    end
  end

  describe ".unproven_seller?" do
    it "is true for a new account with no paid sales" do
      expect(described_class.unproven_seller?(create(:user, email: "new@example.com"))).to be(true)
    end

    it "is false once the account is old enough" do
      expect(described_class.unproven_seller?(create(:user, email: "old@example.com", created_at: 31.days.ago))).to be(false)
    end

    it "is false once the account has a paid sale" do
      seller = create(:user, email: "seller@example.com")
      create(:purchase, link: create(:product, user: seller, price_cents: 500))
      expect(described_class.unproven_seller?(seller)).to be(false)
    end

    it "is false for confirmed Gumroad staff" do
      expect(described_class.unproven_seller?(create(:user, email: "staff@gumroad.com"))).to be(false)
    end
  end

  describe "validations" do
    let(:new_seller) { create(:user, email: "new@example.com") }

    it "rejects a staff-looking product name from a new seller" do
      product = build(:product, user: new_seller, name: "Gumroad Security Team")
      expect(product).not_to be_valid
      expect(product.errors[:name].first).to include("can't look like a message from Gumroad staff")
    end

    it "allows the same product name from an established seller" do
      seller = create(:user, email: "old@example.com", created_at: 1.year.ago)
      expect(build(:product, user: seller, name: "Gumroad Payout Tips and Security")).to be_valid
    end

    it "does not re-check an unchanged name on other edits" do
      product = create(:product, user: create(:user, email: "old@example.com", created_at: 1.year.ago), name: "Gumroad Security Guide")
      product.user.update_columns(created_at: 1.day.ago)
      product.reload.description = "new text"
      expect(product).to be_valid
    end

    it "rejects a staff-looking seller name on a new account" do
      new_seller.name = "Gumroad Payout Verification"
      expect(new_seller).not_to be_valid
      expect(new_seller.errors[:name]).to be_present
    end
  end
end
