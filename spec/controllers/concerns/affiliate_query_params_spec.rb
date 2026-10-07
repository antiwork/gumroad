# frozen_string_literal: true

require "spec_helper"

describe AffiliateQueryParams do
  let(:instance) do
    Class.new do
      include AffiliateQueryParams
    end.new
  end

  describe "#fetch_affiliate_id" do
    it "returns the affiliate id from the affiliate_id param" do
      params = ActionController::Parameters.new(affiliate_id: "123")
      expect(instance.fetch_affiliate_id(params)).to eq(123)
    end

    it "returns the affiliate id from the a param" do
      params = ActionController::Parameters.new(a: "123")
      expect(instance.fetch_affiliate_id(params)).to eq(123)
    end

    it "prefers the affiliate_id param over the a param" do
      params = ActionController::Parameters.new(affiliate_id: "123", a: "456")
      expect(instance.fetch_affiliate_id(params)).to eq(123)
    end

    it "returns nil when no affiliate param is present" do
      params = ActionController::Parameters.new({})
      expect(instance.fetch_affiliate_id(params)).to be_nil
    end

    it "returns nil when the affiliate id is zero" do
      params = ActionController::Parameters.new(a: "0")
      expect(instance.fetch_affiliate_id(params)).to be_nil
    end

    context "when the same affiliate query param is repeated in the URL" do
      it "returns the first affiliate id when affiliate_id is an array" do
        params = ActionController::Parameters.new(affiliate_id: ["1", "2"])
        expect(instance.fetch_affiliate_id(params)).to eq(1)
      end

      it "returns the first affiliate id when a is an array" do
        params = ActionController::Parameters.new(a: ["1", "2"])
        expect(instance.fetch_affiliate_id(params)).to eq(1)
      end
    end

    context "when the affiliate query param is a nested hash" do
      it "returns nil without raising when affiliate_id is a nested hash" do
        params = ActionController::Parameters.new(affiliate_id: { value: "1" })
        expect(instance.fetch_affiliate_id(params)).to be_nil
      end

      it "returns nil without raising when a is a nested hash" do
        params = ActionController::Parameters.new(a: { value: "1" })
        expect(instance.fetch_affiliate_id(params)).to be_nil
      end
    end
  end
end
