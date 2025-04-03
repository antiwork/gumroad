# frozen_string_literal: true

require "spec_helper"

describe Exports::AffiliateExportService do
  describe "#perform" do
    before do
      @product = create(:product, price_cents: 10_00, name: "Product 1")
      @seller = @product.user
      @affiliate_user = create(:affiliate_user, email: "affiliate@gumroad.com", name: "Affiliate 1")
      @direct_affiliate = create(:direct_affiliate, affiliate_user: @affiliate_user, seller: @seller, affiliate_basis_points: 1000, products: [@product])
      @purchase = create(:purchase_in_progress, seller: @seller, link: @product, affiliate: @direct_affiliate)
      @purchase.process!
      @purchase.update_balance_and_mark_successful!
      create(:direct_affiliate, seller: @seller).mark_deleted!
      @service = described_class.new(@seller)
      @service.perform
    end

    it "generates affiliates CSV tempfile with proper data" do
      rows = CSV.parse(@service.tempfile.read)
      expect(rows.size).to eq(3)

      headers, data_row, totals_row = rows.first, rows.second, rows.last
      expect(headers).to match_array described_class::AFFILIATE_FIELDS

      expect(field_value(data_row, "Affiliate ID")).to eq(@direct_affiliate.external_id_numeric.to_s)
      expect(field_value(data_row, "Name")).to eq("Affiliate 1")
      expect(totals_row[0]).to eq("Totals")
      expect(field_value(data_row, "Email")).to eq("affiliate@gumroad.com")
      expect(field_value(data_row, "Fee")).to eq("10 %")
      expect(field_value(data_row, "Sales ($)")).to eq("10.00")
      expect(field_value(totals_row, "Sales ($)")).to eq("10.0")
      expect(field_value(data_row, "Products")).to eq('["Product 1"]')
      expect(field_value(data_row, "Referral URL")).to eq(@direct_affiliate.referral_url)
      expect(field_value(data_row, "Destination URL")).to eq(@direct_affiliate.destination_url)
      expect(field_value(data_row, "Created At")).to eq(@direct_affiliate.created_at.in_time_zone(@direct_affiliate.affiliate_user.timezone).to_date.to_s)
    end

    it "sets a filename" do
      expect(@service.filename).to match(/Affiliates-#{@seller.username}_.*\.csv/)
    end
  end

  describe ".export" do
    before do
      @seller = create(:user)
      create(:direct_affiliate, seller: @seller)
      create(:direct_affiliate, seller: @seller).mark_deleted!
    end

    it "returns performed service when the affiliates count is below the threshold" do
      stub_const("#{described_class}::SYNCHRONOUS_EXPORT_THRESHOLD", 2)
      result = described_class.export(seller: @seller)
      expect(result).to be_a(described_class)
      expect(result.filename).to be_a(String)
      expect(result.tempfile).to be_a(Tempfile)
    end

    it "enqueues job and returns false when the affiliates count is above the threshold" do
      stub_const("#{described_class}::SYNCHRONOUS_EXPORT_THRESHOLD", 0)
      recipient = create(:user)
      result = described_class.export(seller: @seller, recipient:)
      expect(result).to eq(false)
      expect(Exports::AffiliateExportWorker).to have_enqueued_sidekiq_job(@seller.id, recipient.id)
    end
  end

  def field_index(name)
    described_class::AFFILIATE_FIELDS.index(name)
  end

  def field_value(row, name)
    row.fetch(field_index(name))
  end
end
