# frozen_string_literal: true

require "spec_helper"

describe CurrencyHelper do
  describe "per-request lookups (gp#4844)" do
    before { Current.reset }
    after { Current.reset }

    it "looks up the currency of one IP once for the rest of the request" do
      expect(GeoIp).to receive(:lookup).with("203.0.113.9").once.and_return(double(country_code: "FR"))

      results = 5.times.map { buyer_currency_for_ip("203.0.113.9") }

      expect(results).to all(eq("eur"))
    end

    it "reads a USD-based rate once for the rest of the request" do
      namespace = currency_namespace
      namespace.set("EUR", "0.9")
      allow(self).to receive(:currency_namespace).and_return(namespace)
      expect(namespace).to receive(:get).with("EUR").once.and_call_original

      rates = 5.times.map { buyer_local_currency_rate(from_currency: "usd", to_currency: "eur") }

      expect(rates).to all(eq(BigDecimal("0.9")))
    end

    it "checks a seller feature flag once per seller and flag, and keeps sellers apart" do
      one = create(:user)
      other = create(:user)
      Feature.activate_user(:buyer_currency_charging, one)
      expect(Feature).to receive(:active?).with(:buyer_currency_charging, one).once.and_call_original
      expect(Feature).to receive(:active?).with(:buyer_currency_charging, other).once.and_call_original

      expect(3.times.map { seller_feature_active?(:buyer_currency_charging, one) }).to all(be(true))
      expect(3.times.map { seller_feature_active?(:buyer_currency_charging, other) }).to all(be(false))
    end

    it "starts over on the next request" do
      allow(GeoIp).to receive(:lookup).and_return(double(country_code: "FR"))
      buyer_currency_for_ip("203.0.113.9")
      Current.reset
      expect(GeoIp).to receive(:lookup).with("203.0.113.9").once.and_return(double(country_code: "GB"))

      expect(buyer_currency_for_ip("203.0.113.9")).to eq("gbp")
    end
  end
end
