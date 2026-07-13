# frozen_string_literal: true

require "spec_helper"

describe TaxFormTransactionReportJob do
  let(:seller) { create(:user) }
  let(:year) { 2025 }
  let(:stripe_account_id) { "acct_1234567890" }

  let!(:tax_form) { create(:user_tax_form, user: seller, tax_year: year, tax_form_type: "us_1099_k") }
  let!(:merchant_account) { create(:merchant_account, user: seller, charge_processor_merchant_id: stripe_account_id) }

  it "builds the report and emails it to the creator" do
    tempfile = Tempfile.new(["report", ".csv"])
    report = instance_double(Exports::TaxSummary::TransactionReport, perform: tempfile)
    expect(Exports::TaxSummary::TransactionReport).to receive(:new)
      .with(user: seller, year:, stripe_account_id:)
      .and_return(report)

    mail = double("mail", deliver_now: true)
    expect(ContactingCreatorMailer).to receive(:tax_form_transaction_report).with(seller.id, year, tempfile).and_return(mail)

    described_class.new.perform(seller.id, year)
  end

  context "when no 1099-K exists for the year" do
    it "does nothing" do
      expect(ContactingCreatorMailer).not_to receive(:tax_form_transaction_report)

      described_class.new.perform(seller.id, year - 1)
    end
  end

  context "when the stored Stripe account does not belong to the seller" do
    before do
      tax_form.stripe_account_id = "acct_someone_else"
      tax_form.save!
    end

    it "does nothing" do
      expect(ContactingCreatorMailer).not_to receive(:tax_form_transaction_report)

      described_class.new.perform(seller.id, year)
    end
  end

  context "when the seller's matching merchant account has been deleted" do
    before do
      merchant_account.mark_deleted!
    end

    it "does nothing" do
      expect(ContactingCreatorMailer).not_to receive(:tax_form_transaction_report)

      described_class.new.perform(seller.id, year)
    end
  end
end
