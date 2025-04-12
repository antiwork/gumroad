# frozen_string_literal: true

require "spec_helper"

describe Exports::AudienceExportService do
  describe "#perform" do
    let(:user) { create(:user) }
    let(:follower) { create(:active_follower, email: "follower@gumroad.com", user: user) }
    let(:product) { create(:product, user: user, name: "Product 1", price_cents: 100) }
    let(:customer) { create(:purchase, seller: user, link: product) }
    let(:affiliate_user) { create(:affiliate_user) }
    let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller: user) }
    let(:product_affiliate) { create(:product_affiliate, product:, affiliate: direct_affiliate, affiliate_basis_points: 10_00) }

    before do
      user
      follower
      customer
      product_affiliate
    end

    context "when options has followers" do
      it "generates csv with followers" do
        csv = Exports::AudienceExportService.new(user, { followers: true }).perform
        expect(csv).to include "follower@gumroad.com"
        expect(csv).not_to include customer.email
        expect(csv).not_to include affiliate_user.email
      end
    end

    context "when options has customers" do
      it "generates csv with customers" do
        csv = Exports::AudienceExportService.new(user, { customers: true }).perform
        expect(csv).to include customer.email
        expect(csv).not_to include follower.email
        expect(csv).not_to include affiliate_user.email
      end
    end

    context "when options has affiliates" do
      it "generates csv with customers" do
        csv = Exports::AudienceExportService.new(user, { affiliates: true }).perform
        expect(csv).to include affiliate_user.email
        expect(csv).not_to include customer.email
        expect(csv).not_to include follower.email
      end
    end
  end
end
