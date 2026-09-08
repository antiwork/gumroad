# frozen_string_literal: true

describe MoneyFormatter do
  describe "#format" do
    it "formats a registered currency absent from product pricing choices" do
      expect(CURRENCY_CHOICES).not_to have_key(:dkk)
      expect(MoneyFormatter.format(1250, :dkk)).to eq "12.50 kr."
      expect(MoneyFormatter.format(1200, "dkk", no_cents_if_whole: true)).to eq "12 kr."
    end

    it "omits the historical currency symbol only when requested" do
      expect(MoneyFormatter.format(1250, :dkk, symbol: false)).to eq "12.50"
      expect(MoneyFormatter.format(1250, :dkk, symbol: true)).to eq "12.50 kr."
    end

    it "does not relabel an invalid currency as USD" do
      expect { MoneyFormatter.format(1250, :xyz) }.to raise_error(Money::Currency::UnknownCurrency)
      expect { MoneyFormatter.format(1250, :xyz, symbol: false) }.to raise_error(Money::Currency::UnknownCurrency)
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
    end
  end
end
