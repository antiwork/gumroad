# frozen_string_literal: true

require "spec_helper"

describe PurchasingPowerParityService do
  before do
    @namespace = Redis::Namespace.new(:ppp, redis: $redis)
    @service = described_class.new
    @seller = create(:user)
  end

  describe "#get_factor" do
    before do
      @namespace.set("FAKE", "0.9876543210")
    end

    context "when the country code is `nil`" do
      it "produces no errors" do
        expect(@service.get_factor(nil, @seller)).to eq(1)
      end
    end

    context "when the seller has no ppp limit" do
      it "returns the set factor" do
        expect(@service.get_factor("FAKE", @seller)).to eq(0.9876543210)
      end
    end

    context "when the seller's minimum ppp factor is lower than the set factor" do
      before do
        allow(@seller).to receive(:min_ppp_factor).and_return(0.6)
      end
      it "returns the set factor" do
        expect(@service.get_factor("FAKE", @seller)).to eq(0.9876543210)
      end
    end

    context "when the seller's minimum ppp factor is higher than the corresponding factor" do
      before do
        allow(@seller).to receive(:min_ppp_factor).and_return(0.99)
      end
      it "returns the seller's minimum ppp factor" do
        expect(@service.get_factor("FAKE", @seller)).to eq(0.99)
      end
    end
  end

  describe "#set_factor" do
    it "sets the factor" do
      expect { @service.set_factor("FAKE", 0.0123456789) }
        .to change { @service.get_factor("FAKE", @seller) }
        .from(1).to(0.0123456789)
        .and change { @namespace.get("FAKE") }
        .from(nil).to("0.0123456789")
    end
  end

  describe "#get_all_countries_factors" do
    before do
      @seller.update!(purchasing_power_parity_limit: 60)
    end

    it "returns a hash of factors for all countries" do
      @namespace.set("FR", "0.123")
      @namespace.set("IT", "0.456")
      @namespace.set("GB", "0.6")
      result = @service.get_all_countries_factors(@seller)
      expect(result.keys).to eq(Compliance::Countries.mapping.keys)
      expect(result.values.all? { |value| value.is_a?(Float) }).to eq(true)
      expect(result["FR"]).to eq(0.4)
      expect(result["IT"]).to eq(0.456)
      expect(result["GB"]).to eq(0.6)
      expect(result["PL"]).to eq(1.0)
    end
  end
end
