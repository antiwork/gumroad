# frozen_string_literal: true

require "spec_helper"

describe Exports::Payouts::Annual, :vcr do
  include PaymentsHelper

  describe "perform" do
    let!(:year) { 2019 }
    before do
      @user = create(:user)
      date_for_year = Date.new(year)
      amount_cents = 1500
      (0..11).each do |month|
        created_at_date = date_for_year + month.months
        payment = create(:payment_completed,
                         user: @user,
                         amount_cents:,
                         payout_period_end_date: created_at_date,
                         created_at: created_at_date)
        purchase = create(:purchase,
                          seller: @user,
                          price_cents: amount_cents,
                          total_transaction_cents: amount_cents,
                          purchase_success_balance: create(:balance, payments: [payment]),
                          created_at: created_at_date,
                          succeeded_at: created_at_date,
                          link: create(:product, user: @user))
        payment.amount_cents = purchase.payment_cents
        payment.save!
        create(:purchase,
               seller: @user,
               price_cents: amount_cents,
               total_transaction_cents: amount_cents,
               charge_processor_id: PaypalChargeProcessor.charge_processor_id,
               created_at: created_at_date,
               succeeded_at: created_at_date,
               link: create(:product, user: @user))
      end
    end

    it "shows all activity related to the yearly payout" do
      date_for_year = Date.new(year)
      data = Exports::Payouts::Annual.new(user: @user, year:).perform
      parsed_csv = CSV.parse(data[:csv_file].read)
      expect(parsed_csv).to include(Exports::Payouts::Csv::HEADERS)
      @user.sales.where("created_at BETWEEN ? AND ?",
                        date_for_year.beginning_of_year,
                        date_for_year.at_end_of_year).each do |sale|
        expect(parsed_csv).to include(sale_summary(sale))
      end
      expect(parsed_csv.last).to eq(["Totals", nil, nil, nil, nil, nil, "0.0", "0.0", "212.88", "65.76", "147.12"])
    end

    it "returns total_amount from the yearly payout" do
      date_for_year = Date.new(year)
      data = Exports::Payouts::Annual.new(user: @user, year:).perform
      amount = (data[:total_amount] * 100.0).round
      expect(amount).to eq(@user.sales.where("created_at BETWEEN ? AND ?",
                                             date_for_year.beginning_of_year,
                                             date_for_year.at_end_of_year).sum("price_cents - fee_cents"))
    end

    it "returns no data if no payments exist" do
      data = Exports::Payouts::Annual.new(user: create(:user), year:).perform
      expect(data[:csv_file]).to be_nil
    end

    it "returns no data on failed payments" do
      date_for_year = Date.new(year)
      payment_data = create_payment_with_purchase(@user, date_for_year, :payment_failed)
      data = Exports::Payouts::Annual.new(user: @user, year:).perform
      parsed_csv = CSV.parse(data[:csv_file].read)
      expect(parsed_csv).not_to include(sale_summary(payment_data[:purchase]))
    end

    it "does not return sales falling on days not in given year" do
      payment_data = create_payment_with_purchase(@user, Date.new(year) - 3.days)
      data = Exports::Payouts::Annual.new(user: @user, year:).perform
      parsed_csv = CSV.parse(data[:csv_file].read)
      expect(parsed_csv).to_not include(sale_summary(payment_data[:purchase]))
    end
  end

  private
    def sale_summary(sale)
      CSV.parse([
        "Sale",
        sale.succeeded_at.to_date.to_s,
        sale.external_id,
        sale.link.name,
        sale.full_name,
        sale.purchaser_email_or_email,
        sale.tax_dollars,
        sale.shipping_dollars,
        sale.price_dollars,
        sale.fee_dollars,
        sale.net_total,
      ].to_csv).first
    end
end
