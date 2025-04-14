# frozen_string_literal: true

require "spec_helper"

describe Exports::AudienceExportService do
  describe "#perform" do
    let!(:user) { create(:user) }
    let!(:follower) { create(:active_follower, email: "follower@gumroad.com", user: user, created_at: 1.day.ago) }
    let(:product) { create(:product, user: user, name: "Product 1", price_cents: 100) }
    let!(:customer) { create(:purchase, seller: user, link: product, created_at: 2.days.ago) }
    let(:affiliate_user) { create(:affiliate_user, created_at: 4.days.ago) }
    let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller: user, created_at: 3.days.ago) }
    let!(:product_affiliate) { create(:product_affiliate, product:, affiliate: direct_affiliate, affiliate_basis_points: 10_00) }

    subject { described_class.new(user, options) }

    context "when options has followers" do
      let(:options) { { followers: true } }

      it "generates csv with followers" do
        rows = CSV.parse(subject.perform.tempfile.read)

        expect(rows.size).to eq(2)
        headers, data_row = rows.first, rows.second

        expect(headers).to eq(described_class::FIELDS)
        expect(data_row.first).to eq(follower.email)
        expect(data_row.second).to eq(follower.created_at.to_s)
      end
    end

    context "when options has customers" do
      let(:options) { { customers: true } }

      it "generates csv with customers" do
        rows = CSV.parse(subject.perform.tempfile.read)

        expect(rows.size).to eq(2)
        headers, data_row = rows.first, rows.second

        expect(headers).to eq(described_class::FIELDS)
        expect(data_row.first).to eq(customer.email)
        expect(data_row.second).to eq(customer.created_at.to_s)
      end
    end

    context "when options has affiliates" do
      let(:options) { { affiliates: true } }

      it "generates csv with customers" do
        rows = CSV.parse(subject.perform.tempfile.read)

        expect(rows.size).to eq(2)
        headers, data_row = rows.first, rows.second

        expect(headers).to eq(described_class::FIELDS)
        expect(data_row.first).to eq(affiliate_user.email)
        expect(data_row.second).to eq(direct_affiliate.created_at.to_s)
      end
    end

    context "when options has all audience types" do
      let(:options) { { followers: true, customers: true, affiliates: true } }

      it "generates csv with all audience types" do
        rows = CSV.parse(subject.perform.tempfile.read)

        expect(rows.size).to eq(4)
        headers = rows.first

        expect(headers).to eq(described_class::FIELDS)
        expect(rows[1].first).to eq(follower.email)
        expect(rows[1].second).to eq(follower.created_at.to_s)
        expect(rows[2].first).to eq(customer.email)
        expect(rows[2].second).to eq(customer.created_at.to_s)
        expect(rows[3].first).to eq(affiliate_user.email)
        expect(rows[3].second).to eq(direct_affiliate.created_at.to_s)
      end
    end

    context "when user is both a follower and a customer" do
      let(:options) { { followers: true, customers: true } }
      let!(:follower_customer) { create(:active_follower, email: customer.email, user:, created_at: 1000.day.ago) }

      it "generates csv with unique entries with minimum created_at" do
        rows = CSV.parse(subject.perform.tempfile.read)

        expect(rows.size).to eq(3)
        headers = rows.first

        expect(headers).to eq(described_class::FIELDS)
        expect(rows[1].first).to eq(follower.email)
        expect(rows[1].second).to eq(follower.created_at.to_s)
        expect(rows[2].first).to eq(follower_customer.email)
        expect(rows[2].second).to eq(follower_customer.created_at.to_s)
      end
    end

    context "when no options are provided" do
      let(:options) { {} }

      it "raises an ArgumentError" do
        expect { described_class.new(user, {}) }.to raise_error(ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected")
      end
    end
  end
end
