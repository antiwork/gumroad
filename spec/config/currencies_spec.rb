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

  it "defines the eight new currencies with 100 subunits and the configured floors" do
    expect(CURRENCY_CHOICES[:sar]).to eq("symbol" => "SAR", "display_format" => "SAR (Saudi riyal)", "min_price" => 372)
    expect(CURRENCY_CHOICES[:aed]).to eq("symbol" => "AED", "display_format" => "AED (UAE dirham)", "min_price" => 364)
    expect(CURRENCY_CHOICES[:try]).to eq("symbol" => "₺", "display_format" => "₺ (Turkish lira)", "min_price" => 4812)
    expect(CURRENCY_CHOICES[:cop]).to eq(
      "symbol" => "COL$",
      "display_format" => "COL$ (Colombian peso)",
      "short_symbol" => "$",
      "min_price" => 307474
    )
    expect(CURRENCY_CHOICES[:ron]).to eq("symbol" => "lei", "display_format" => "lei (Romanian leu)", "min_price" => 449)
    expect(CURRENCY_CHOICES[:thb]).to eq("symbol" => "฿", "display_format" => "฿ (Thai baht)", "min_price" => 3270)
    expect(CURRENCY_CHOICES[:myr]).to eq("symbol" => "RM", "display_format" => "RM (Malaysian ringgit)", "min_price" => 403)
    expect(CURRENCY_CHOICES[:idr]).to eq("symbol" => "Rp", "display_format" => "Rp (Indonesian rupiah)", "min_price" => 1743007)

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
      "Saudi riyal", "UAE dirham", "Turkish lira", "Colombian peso",
      "Romanian leu", "Thai baht", "Malaysian ringgit", "Indonesian rupiah",
      "Korean won", "Taiwanese dollars"
    )
  end
end
