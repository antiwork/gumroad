# frozen_string_literal: true

require "spec_helper"

describe Exports::AudienceExportService do
  describe "#perform" do
    let(:seller) { create(:user) }
    let(:follower_created_at) { 1.day.ago }
    let(:customer_created_at) { 2.days.ago }
    let(:affiliate_created_at) { 3.days.ago }

    let!(:follower_member) do
      create(:audience_member,
        seller:,
        email: "follower@example.com",
        follower: { id: 1, created_at: follower_created_at.iso8601 })
    end

    let!(:customer_member) do
      create(:audience_member,
        seller:,
        email: "customer@example.com",
        purchases: [{ id: 1, product_id: 1, price_cents: 100, created_at: customer_created_at.iso8601, country: "United States" }])
    end

    let!(:affiliate_member) do
      create(:audience_member,
        seller:,
        email: "affiliate@example.com",
        affiliates: [{ id: 1, product_id: 1, created_at: affiliate_created_at.iso8601 }])
    end

    subject { described_class.new(seller, options) }

    context "when options has followers" do
      let(:options) { { followers: true } }

      it "generates csv with followers" do
        rows = CSV.parse(subject.perform.tempfile.read)

        expect(rows.size).to eq(2)
        headers, data_row = rows.first, rows.second

        expect(headers).to eq(described_class::FIELDS)
        expect(data_row.first).to eq(follower_member.email)
        expect(data_row.second).to eq(follower_member.min_created_at.to_s)
      end
    end

    context "when options has customers" do
      let(:options) { { customers: true } }

      it "generates csv with customers" do
        rows = CSV.parse(subject.perform.tempfile.read)

        expect(rows.size).to eq(2)
        headers, data_row = rows.first, rows.second

        expect(headers).to eq(described_class::FIELDS)
        expect(data_row.first).to eq(customer_member.email)
        expect(data_row.second).to eq(customer_member.min_created_at.to_s)
      end
    end

    context "when options has affiliates" do
      let(:options) { { affiliates: true } }

      it "generates csv with affiliates" do
        rows = CSV.parse(subject.perform.tempfile.read)

        expect(rows.size).to eq(2)
        headers, data_row = rows.first, rows.second

        expect(headers).to eq(described_class::FIELDS)
        expect(data_row.first).to eq(affiliate_member.email)
        expect(data_row.second).to eq(affiliate_member.min_created_at.to_s)
      end
    end

    context "when options has all audience types" do
      let(:options) { { followers: true, customers: true, affiliates: true } }

      it "generates csv with all audience types" do
        rows = CSV.parse(subject.perform.tempfile.read)

        expect(rows.size).to eq(4)
        headers = rows.first

        expect(headers).to eq(described_class::FIELDS)

        emails = rows[1..].map(&:first)
        expect(emails).to contain_exactly(
          follower_member.email,
          customer_member.email,
          affiliate_member.email
        )
      end
    end

    context "when user is both a follower and a customer" do
      let(:options) { { followers: true, customers: true } }
      let(:earliest_created_at) { 100.days.ago }

      let!(:follower_and_customer_member) do
        create(:audience_member,
          seller:,
          email: "both@example.com",
          follower: { id: 2, created_at: earliest_created_at.iso8601 },
          purchases: [{ id: 2, product_id: 1, price_cents: 100, created_at: 10.days.ago.iso8601, country: "United States" }])
      end

      it "generates csv with unique entries" do
        rows = CSV.parse(subject.perform.tempfile.read)

        expect(rows.size).to eq(4)
        headers = rows.first

        expect(headers).to eq(described_class::FIELDS)

        emails = rows[1..].map(&:first)
        expect(emails).to contain_exactly(
          follower_member.email,
          customer_member.email,
          follower_and_customer_member.email
        )
        expect(emails.uniq.size).to eq(emails.size)
      end
    end

    context "when no options are provided" do
      let(:options) { {} }

      it "raises an ArgumentError" do
        expect { described_class.new(seller, {}) }.to raise_error(ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected")
      end
    end

    context "with large dataset" do
      let(:options) { { followers: true } }

      it "processes records in batches" do
        stub_const("#{described_class}::BATCH_SIZE", 2)

        additional_members = 5.times.map do |i|
          create(:audience_member,
            seller:,
            email: "follower#{i}@example.com",
            follower: { id: i + 10, created_at: (i + 5).days.ago.iso8601 })
        end

        rows = CSV.parse(subject.perform.tempfile.read)

        expect(rows.size).to eq(7)
        emails = rows[1..].map(&:first)
        expect(emails).to include(follower_member.email)
        additional_members.each do |member|
          expect(emails).to include(member.email)
        end
      end
    end
  end
end
