# frozen_string_literal: true

require "spec_helper"

describe "config/currencies.json" do
  let(:added) { %w[sek nok dkk mxn] }
  let(:help_article) do
    Rails.root.join("app/views/help_center/articles/contents/_46-what-currency-does-gumroad-use.html.erb").read
  end

  it "keeps one 23-currency pricing list including EUR and the four new buyer currencies" do
    expect(CURRENCY_CHOICES.keys.map(&:to_s)).to eq(
      %w[usd gbp eur jpy inr aud cad hkd sgd twd nzd brl zar chf ils php krw pln czk sek nok dkk mxn]
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
    expect(CURRENCY_CHOICES).not_to have_key(:thb)
    expect(Currency::THB).to eq("thb")
  end

  it "lists the new checkout currencies in the public help article" do
    expect(help_article).to include("Swedish krona", "Norwegian krone", "Danish krone", "Mexican peso")
  end
end
