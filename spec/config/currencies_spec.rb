# frozen_string_literal: true

require "spec_helper"

describe "config/currencies.json" do
  let(:added) { %w[sar aed try cop ron thb myr idr] }
  let(:help_article) do
    Rails.root.join("app/views/help_center/articles/contents/_46-what-currency-does-gumroad-use.html.erb").read
  end

  it "keeps one 31-currency pricing list including EUR, KRW, TWD and the eight new buyer currencies" do
    expect(CURRENCY_CHOICES.keys.map(&:to_s)).to eq(
      %w[usd gbp eur jpy inr aud cad hkd sgd twd nzd brl zar chf ils php krw pln czk sek nok dkk mxn sar aed try cop ron thb myr idr]
    )
  end

  it "leaves the euro entry unchanged" do
    expect(CURRENCY_CHOICES[:eur]).to eq(
      "symbol" => "€",
      "display_format" => "€ (Euro)",
      "min_price" => 79
    )
  end

  it "defines SEK, NOK, DKK, MXN and the eight new buyer currencies with 100 subunits and the configured floors" do
    expect(CURRENCY_CHOICES[:sek]).to eq("symbol" => "kr", "display_format" => "kr (Swedish Krona)", "min_price" => 999)
    expect(CURRENCY_CHOICES[:nok]).to eq("symbol" => "kr", "display_format" => "kr (Norwegian Krone)", "min_price" => 949)
    expect(CURRENCY_CHOICES[:dkk]).to eq("symbol" => "kr", "display_format" => "kr (Danish Krone)", "min_price" => 649)
    expect(CURRENCY_CHOICES[:mxn]).to eq(
      "symbol" => "MX$",
      "display_format" => "MX$ (Mexican Peso)",
      "short_symbol" => "$",
      "min_price" => 1699
    )
    expect(CURRENCY_CHOICES[:sar]).to eq("symbol" => "SAR", "display_format" => "SAR (Saudi Riyal)", "min_price" => 372)
    expect(CURRENCY_CHOICES[:aed]).to eq("symbol" => "AED", "display_format" => "AED (UAE Dirham)", "min_price" => 364)
    expect(CURRENCY_CHOICES[:try]).to eq("symbol" => "₺", "display_format" => "₺ (Turkish Lira)", "min_price" => 4812)
    expect(CURRENCY_CHOICES[:cop]).to eq(
      "symbol" => "COL$",
      "display_format" => "COL$ (Colombian Peso)",
      "short_symbol" => "$",
      "min_price" => 307474
    )
    expect(CURRENCY_CHOICES[:ron]).to eq("symbol" => "lei", "display_format" => "lei (Romanian Leu)", "min_price" => 449)
    expect(CURRENCY_CHOICES[:thb]).to eq("symbol" => "฿", "display_format" => "฿ (Thai Baht)", "min_price" => 3270)
    expect(CURRENCY_CHOICES[:myr]).to eq("symbol" => "RM", "display_format" => "RM (Malaysian Ringgit)", "min_price" => 403)
    expect(CURRENCY_CHOICES[:idr]).to eq("symbol" => "Rp", "display_format" => "Rp (Indonesian Rupiah)", "min_price" => 1743007)

    added.each do |code|
      expect(CURRENCY_CHOICES[code]).not_to have_key(:single_unit)
      expect(Currency.const_get(code.upcase)).to eq(code)
      expect(StripeChargeProcessor.charge_minor_units_compatible?(code)).to be(true)
      expect(Money::Currency.new(code).subunit_to_unit).to eq(100)
    end
  end

  it "lets KRW and TWD through the checkout minor-unit gate" do
    expect(StripeChargeProcessor.charge_minor_units_compatible?("krw")).to be(true)
    expect(StripeChargeProcessor.charge_minor_units_compatible?("twd")).to be(true)
    expect(StripeChargeProcessor.charge_subunit_to_unit("krw")).to eq(1)
    expect(StripeChargeProcessor.charge_subunit_to_unit("twd")).to eq(100)
    expect(StripeChargeProcessor.align_charge_amount_cents(32_258, "twd")).to eq(32_300)
  end

  it "keeps payout-only currencies out of the pricing list" do
    expect(CURRENCY_CHOICES).not_to have_key(:pen)
    expect(Currency::PEN).to eq("pen")
  end

  it "lists the new checkout currencies in the public help article" do
    expect(help_article).to include(
      "Swedish Krona", "Norwegian Krone", "Danish Krone", "Mexican Peso",
      "Saudi Riyal", "UAE Dirham", "Turkish Lira", "Colombian Peso",
      "Romanian Leu", "Thai Baht", "Malaysian Ringgit", "Indonesian Rupiah",
      "Korean Won", "Taiwanese Dollars"
    )
  end
end
