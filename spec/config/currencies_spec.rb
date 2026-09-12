# frozen_string_literal: true

require "spec_helper"

describe "config/currencies.json" do
  let(:added) { %w[sek nok dkk mxn] }
  let(:help_article) do
    Rails.root.join("app/views/help_center/articles/contents/_46-what-currency-does-gumroad-use.html.erb").read
  end

  it "keeps one 31-currency pricing list including EUR and the new buyer currencies" do
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

  it "defines SEK, NOK, DKK and MXN with 100 subunits and the configured floors" do
    expect(CURRENCY_CHOICES[:sek]).to eq("symbol" => "kr", "display_format" => "kr (Swedish krona)", "min_price" => 999)
    expect(CURRENCY_CHOICES[:nok]).to eq("symbol" => "kr", "display_format" => "kr (Norwegian krone)", "min_price" => 949)
    expect(CURRENCY_CHOICES[:dkk]).to eq("symbol" => "kr", "display_format" => "kr (Danish krone)", "min_price" => 649)
    expect(CURRENCY_CHOICES[:mxn]).to eq(
      "symbol" => "MX$",
      "display_format" => "MX$ (Mexican peso)",
      "short_symbol" => "$",
      "min_price" => 1699
    )

    added.each do |code|
      expect(CURRENCY_CHOICES[code]).not_to have_key(:single_unit)
      expect(Currency.const_get(code.upcase)).to eq(code)
      expect(StripeChargeProcessor.charge_minor_units_compatible?(code)).to be(true)
      expect(Money::Currency.new(code).subunit_to_unit).to eq(100)
    end
  end

  it "keeps payout-only currencies out of the pricing list" do
    expect(CURRENCY_CHOICES).not_to have_key(:huf)
    expect(Currency::HUF).to eq("huf")
  end

  it "lists the new checkout currencies in the public help article" do
    expect(help_article).to include("Swedish krona", "Norwegian krone", "Danish krone", "Mexican peso")
  end

  it "defines the eight additional buyer currencies with two decimal places" do
    expect(CURRENCY_CHOICES[:sar]).to eq("symbol" => "SAR", "display_format" => "SAR (Saudi riyal)", "min_price" => 372)
    expect(CURRENCY_CHOICES[:aed]).to eq("symbol" => "AED", "display_format" => "AED (UAE dirham)", "min_price" => 364)
    expect(CURRENCY_CHOICES[:try]).to eq("symbol" => "₺", "display_format" => "₺ (Turkish lira)", "min_price" => 4795)
    expect(CURRENCY_CHOICES[:cop]).to eq("symbol" => "COP$", "display_format" => "COP$ (Colombian peso)", "min_price" => 305678, "short_symbol" => "$")
    expect(CURRENCY_CHOICES[:ron]).to eq("symbol" => "lei", "display_format" => "lei (Romanian leu)", "min_price" => 449)
    expect(CURRENCY_CHOICES[:thb]).to eq("symbol" => "฿", "display_format" => "฿ (Thai baht)", "min_price" => 3267)
    expect(CURRENCY_CHOICES[:myr]).to eq("symbol" => "RM", "display_format" => "RM (Malaysian ringgit)", "min_price" => 403)
    expect(CURRENCY_CHOICES[:idr]).to eq("symbol" => "Rp", "display_format" => "Rp (Indonesian rupiah)", "min_price" => 1743103)

    %w[sar aed try cop ron thb myr idr].each do |code|
      expect(Currency.const_get(code.upcase)).to eq(code)
      expect(StripeChargeProcessor.charge_minor_units_compatible?(code)).to be(true)
      expect(Money::Currency.new(code).subunit_to_unit).to eq(100)
    end
  end

  it "documents the eight additional checkout currencies" do
    expect(help_article).to include("Saudi riyal", "UAE dirham", "Turkish lira", "Colombian peso", "Romanian leu", "Thai baht", "Malaysian ringgit", "Indonesian rupiah")
  end
end
