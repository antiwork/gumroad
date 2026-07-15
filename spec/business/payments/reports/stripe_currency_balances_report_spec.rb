# frozen_string_literal: true

describe StripeCurrencyBalancesReport do
  describe ".stripe_currency_balances_report" do
    before do
      balance = {
        available: [
          { currency: "usd", amount: 617_402_08 },
          { currency: "gbp", amount: -50_000_00 },
          { currency: "jpy", amount: 12_345 },
        ],
        pending: [
          { currency: "usd", amount: 10_000_00 },
          { currency: "gbp", amount: -1_000_00 },
        ],
        connect_reserved: [
          { currency: "usd", amount: 5_000_00 },
        ],
      }
      allow(Stripe::Balance).to receive(:retrieve).and_return(double("balance", to_hash: balance))

      allow(described_class).to receive(:cached_usd_rate).and_return(nil)
      allow(described_class).to receive(:cached_usd_rate).with("usd").and_return(BigDecimal("1"))
      allow(described_class).to receive(:cached_usd_rate).with("gbp").and_return(BigDecimal("0.8"))
    end

    it "sums available, pending, and connect_reserved per currency and converts totals to USD" do
      rows = CSV.parse(described_class.stripe_currency_balances_report)

      expect(rows.first).to eq(["Currency", "Available", "Pending", "Connect reserved", "Total", "USD equivalent"])
      expect(rows).to include(["usd", "617402.08", "10000.0", "5000.0", "632402.08", "632402.08"])
      expect(rows).to include(["gbp", "-50000.0", "-1000.0", "0.0", "-51000.0", "-63750.0"])
    end

    it "reports single-unit currencies without dividing by 100 and leaves the USD column blank when no rate is cached" do
      rows = CSV.parse(described_class.stripe_currency_balances_report)

      jpy_row = rows.find { |row| row.first == "jpy" }
      expect(jpy_row).to eq(["jpy", "12345", "0", "0", "12345", nil])
    end

    it "sorts rows by currency code" do
      rows = CSV.parse(described_class.stripe_currency_balances_report)

      expect(rows.drop(1).map(&:first)).to eq(%w[gbp jpy usd])
    end
  end
end
