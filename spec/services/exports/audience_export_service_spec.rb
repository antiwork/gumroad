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

    subject { described_class.new(user, options) }

    before do
      user
      follower
      customer
      product_affiliate

      subject.perform
    end

    context "when options has followers" do
      let(:options) { { followers: true } }

      it "generates csv with followers" do
        rows = CSV.parse(subject.tempfile.read)

        expect(rows.size).to eq(2)
        headers, data_row = rows.first, rows.second

        expect(headers).to match_array(described_class::FIELDS)
        expect(data_row.first).to eq(follower.email)
      end
    end

    context "when options has customers" do
      let(:options) { { customers: true } }

      it "generates csv with customers" do
        rows = CSV.parse(subject.tempfile.read)

        expect(rows.size).to eq(2)
        headers, data_row = rows.first, rows.second

        expect(headers).to match_array(described_class::FIELDS)
        expect(data_row.first).to eq(customer.email)
      end
    end

    context "when options has affiliates" do
      let(:options) { { affiliates: true } }

      it "generates csv with customers" do
        rows = CSV.parse(subject.tempfile.read)

        expect(rows.size).to eq(2)
        headers, data_row = rows.first, rows.second

        expect(headers).to match_array(described_class::FIELDS)
        expect(data_row.first).to eq(affiliate_user.email)
      end
    end
  end
end
