# frozen_string_literal: true

describe MoneyFormatter do
  describe "#format" do
    it "formats a registered currency absent from product pricing choices" do
      expect(CURRENCY_CHOICES).not_to have_key(:huf)
      expect(MoneyFormatter.format(1250, :huf)).to eq "12.50 Ft"
      expect(MoneyFormatter.format(1200, "huf", no_cents_if_whole: true)).to eq "12 Ft"
    end

    it "omits the historical currency symbol only when requested" do
      expect(MoneyFormatter.format(1250, :huf, symbol: false)).to eq "12.50"
      expect(MoneyFormatter.format(1250, :huf, symbol: true)).to eq "12.50 Ft"
    end

    it "uses the configured pricing symbol for Nordic and Mexican currencies" do
      expect(MoneyFormatter.format(1250, :dkk)).to eq "12.50 kr"
      expect(MoneyFormatter.format(1200, "sek", no_cents_if_whole: true)).to eq "12 kr"
      expect(MoneyFormatter.format(1250, :nok)).to eq "12.50 kr"
      expect(MoneyFormatter.format(1250, :mxn)).to eq "MX$12.50"
    end

    it "soft-fails unknown currencies with the ISO code instead of relabeling them as USD" do
      expect(Rails.logger).to receive(:warn).with(/unknown currency :xyz/).at_least(:once)
      expect(MoneyFormatter.format(1250, :xyz)).to eq "12.50 XYZ"
      expect(MoneyFormatter.format(1250, :xyz, symbol: false)).to eq "12.50"
      expect(MoneyFormatter.format(1250, :xyz)).not_to include("$")
    end

    it "soft-fails blank currencies without raising" do
      expect(Rails.logger).to receive(:warn).with(/unknown currency/).at_least(:once)
      expect(MoneyFormatter.format(1250, nil)).to eq "12.50"
      expect(MoneyFormatter.format(1250, "")).to eq "12.50"
    end

    describe "usd" do
      it "returns the correct string" do
        expect(MoneyFormatter.format(400, :usd)).to eq "$4.00"
      end

      it "returns correctly when no symbol desired" do
        expect(MoneyFormatter.format(400, :usd, symbol: false)).to eq "4.00"
      end
    end

    describe "jpy" do
      it "returns the correct string" do
        expect(MoneyFormatter.format(400, :jpy)).to eq "¥400"
      end
    end

    describe "aud" do
      it "returns the correct currency symbol" do
        expect(MoneyFormatter.format(400, :aud)).to eq "A$4.00"
      end

      it "honors uppercase pricing-choice keys" do
        expect(MoneyFormatter.format(400, "AUD")).to eq "A$4.00"
      end
    end
  end

  describe "#symbol_for" do
    it "uses the pricing override before the registry" do
      expect(MoneyFormatter.symbol_for(:aud)).to eq "A$"
      expect(MoneyFormatter.symbol_for("AUD")).to eq "A$"
    end

    it "uses the registry symbol for historical currencies" do
      expect(MoneyFormatter.symbol_for(:huf)).to eq "Ft"
    end

    it "uses the configured pricing symbol for Nordic and Mexican currencies" do
      expect(MoneyFormatter.symbol_for(:dkk)).to eq "kr"
      expect(MoneyFormatter.symbol_for(:sek)).to eq "kr"
      expect(MoneyFormatter.symbol_for(:nok)).to eq "kr"
      expect(MoneyFormatter.symbol_for(:mxn)).to eq "MX$"
    end

    it "soft-fails unknown currencies with the ISO code instead of relabeling them as USD" do
      expect(Rails.logger).to receive(:warn).with(/unknown currency :xyz/)
      symbol = MoneyFormatter.symbol_for(:xyz)
      expect(symbol).to eq("XYZ")
      expect(symbol).not_to eq("$")
    end

    it "soft-fails blank currencies with an empty string" do
      expect(Rails.logger).to receive(:warn).with(/unknown currency/).twice
      expect(MoneyFormatter.symbol_for(nil)).to eq ""
      expect(MoneyFormatter.symbol_for("")).to eq ""
    end
  end

  it "uses the configured symbols for the eight additional buyer currencies" do
    expect(MoneyFormatter.symbol_for(:sar)).to eq("SAR")
    expect(MoneyFormatter.format(1234, :sar, symbol: false)).to eq("12.34")
    expect(MoneyFormatter.symbol_for(:aed)).to eq("AED")
    expect(MoneyFormatter.format(1234, :aed, symbol: false)).to eq("12.34")
    expect(MoneyFormatter.symbol_for(:try)).to eq("₺")
    expect(MoneyFormatter.format(1234, :try, symbol: false)).to eq("12.34")
    expect(MoneyFormatter.symbol_for(:cop)).to eq("COP$")
    expect(MoneyFormatter.format(1234, :cop, symbol: false)).to eq("12.34")
    expect(MoneyFormatter.symbol_for(:ron)).to eq("lei")
    expect(MoneyFormatter.format(1234, :ron, symbol: false)).to eq("12.34")
    expect(MoneyFormatter.symbol_for(:thb)).to eq("฿")
    expect(MoneyFormatter.format(1234, :thb, symbol: false)).to eq("12.34")
    expect(MoneyFormatter.symbol_for(:myr)).to eq("RM")
    expect(MoneyFormatter.format(1234, :myr, symbol: false)).to eq("12.34")
    expect(MoneyFormatter.symbol_for(:idr)).to eq("Rp")
    expect(MoneyFormatter.format(1234, :idr, symbol: false)).to eq("12.34")
  end
end
