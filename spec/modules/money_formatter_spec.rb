# frozen_string_literal: true

describe MoneyFormatter do
  describe "#format" do
    it "formats a registered currency absent from product pricing choices" do
      expect(CURRENCY_CHOICES).not_to have_key(:pen)
      expect(MoneyFormatter.format(1250, :pen)).to eq "S/12.50"
      expect(MoneyFormatter.format(1200, "pen", no_cents_if_whole: true)).to eq "S/12"
    end

    it "omits the historical currency symbol only when requested" do
      expect(MoneyFormatter.format(1250, :pen, symbol: false)).to eq "12.50"
      expect(MoneyFormatter.format(1250, :pen, symbol: true)).to eq "S/12.50"
    end

    it "uses the configured pricing symbol for Nordic, Mexican and newly added currencies" do
      expect(MoneyFormatter.format(1250, :dkk)).to eq "12.50 kr"
      expect(MoneyFormatter.format(1200, "sek", no_cents_if_whole: true)).to eq "12 kr"
      expect(MoneyFormatter.format(1250, :nok)).to eq "12.50 kr"
      expect(MoneyFormatter.format(1250, :mxn)).to eq "MX$12.50"
      expect(MoneyFormatter.format(1250, :thb)).to eq "฿12.50"
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
      expect(MoneyFormatter.symbol_for(:pen)).to eq "S/"
    end

    it "uses the configured pricing symbol for Nordic, Mexican and newly added currencies" do
      expect(MoneyFormatter.symbol_for(:dkk)).to eq "kr"
      expect(MoneyFormatter.symbol_for(:sek)).to eq "kr"
      expect(MoneyFormatter.symbol_for(:nok)).to eq "kr"
      expect(MoneyFormatter.symbol_for(:mxn)).to eq "MX$"
      expect(MoneyFormatter.symbol_for(:thb)).to eq "฿"
      expect(MoneyFormatter.symbol_for(:sar)).to eq "SAR"
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
end
