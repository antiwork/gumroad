# frozen_string_literal: true

require "spec_helper"

describe Exports::TaxSummary::Annual, :vcr do
  include PaymentsHelper

  describe "perform" do
    let!(:year) { 2019 }
    before do
      date_in_year = Date.new(year)
      @user = create(:user)
      @compliance_info = create(:user_compliance_info, user: @user)
      @merchant_account_stripe = create(:merchant_account_stripe, user: @user)
      create(:tos_agreement, user: @user)
      @payments = {}
      @payments[date_in_year] = create_payment_with_purchase(@user, date_in_year)[:payment]
      11.downto(1).each do |i|
        @payments[date_in_year + i.months] = create_payment_with_purchase(@user, date_in_year + i.months)[:payment]
      end

      # To simulate the exports
      stub_const("User::Taxation::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING", 10)
      stub_const("User::Taxation::MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING", 1)
    end

    it "does not export for non compliant users" do
      UserComplianceInfo.delete_all
      csv_url = described_class.new(year:).perform
      URI.open(csv_url) do |f|
        csv_data = CSV.parse f.read
        expect(csv_data).to be_empty
      end
    end

    it "does not export for non-us users" do
      @compliance_info.destroy
      @compliance_info = create(:user_compliance_info, user: @user, country: Compliance::Countries::GBR.common_name)
      csv_url = described_class.new(year:).perform
      URI.open(csv_url) do |f|
        csv_data = CSV.parse f.read
        expect(csv_data).to be_empty
      end
    end

    it "does not export for invalid compliance country users" do
      UserComplianceInfo.delete_all
      @compliance_info = create(:user_compliance_info, user: @user)
      UserComplianceInfo.update_all(country: "Aland Islands")
      csv_url = described_class.new(year:).perform
      URI.open(csv_url) do |f|
        csv_data = CSV.parse f.read
        expect(csv_data).to be_empty
      end
    end

    it "does not export users without min sales amount" do
      stub_const("User::Taxation::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING", 100_000)
      csv_url = described_class.new(year:).perform
      URI.open(csv_url) do |f|
        csv_data = CSV.parse f.read
        expect(csv_data).to be_empty
      end
    end

    it "generates total transactions amount" do
      csv_url = described_class.new(year:).perform
      URI.open(csv_url) do |f|
        parsed_csv = CSV.parse f.read
        total_amount = @payments.values.collect(&:amount_cents).sum(0) / 100.0
        expect(parsed_csv[1][21]).to eq(total_amount.to_s)
      end
    end

    it "creates monthly breakdown with transaction amount" do
      csv_url = described_class.new(year:).perform

      URI.open(csv_url) do |f|
        parsed_csv = CSV.parse f.read
        expect(parsed_csv[1][26..37].sort).to eq @payments.values.collect { |payment| (payment.amount_cents / 100.0).to_s }.sort
      end
    end

    it "returns compliance and other user related fields" do
      csv_url = described_class.new(year:).perform
      URI.open(csv_url) do |f|
        parsed_csv = CSV.parse f.read
        row = parsed_csv[1]
        expect(row[1]).to eq(@user.external_id)
        expect(row[2]).to eq(@merchant_account_stripe.charge_processor_merchant_id)
        expect(row[3..6]).to eq([@compliance_info.first_and_last_name, @compliance_info.first_name, @compliance_info.last_name, @compliance_info.legal_entity_name])
        expect(row[7]).to eq(@user.email)
        expect(row[8..13]).to eq([@compliance_info.legal_entity_street_address, nil, @compliance_info.legal_entity_city, @compliance_info.legal_entity_state_code, @compliance_info.legal_entity_zip_code, @compliance_info.legal_entity_country_code,])
        expect(row[14]).to eq(@compliance_info.legal_entity_payable_business_type)

        expect(row[17]).to eq "EPF Other"
        expect(row[18]).to eq "Third Party Network"
        expect(row[19]).to eq "Gumroad"
        expect(row[20]).to eq "(650) 204-3486"
      end
    end

    it "adds tax id if user is an individual" do
      csv_url = described_class.new(year:).perform
      URI.open(csv_url) do |f|
        parsed_csv = CSV.parse f.read
        row = parsed_csv[1]
        expect(row[15]).to eq(@compliance_info.individual_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")))
      end
    end

    it "adds business tax id if user is a business" do
      @user.user_compliance_infos.delete_all
      @compliance_info = create(:user_compliance_info_business, user: @user)

      csv_url = described_class.new(year:).perform
      URI.open(csv_url) do |f|
        parsed_csv = CSV.parse f.read
        row = parsed_csv[1]
        expect(row[16]).to eq(@compliance_info.business_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")))
      end
    end
  end
end
