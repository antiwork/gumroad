# frozen_string_literal: true

require "spec_helper"

describe StripeUrl do
  describe "dashboard_url" do
    describe "production" do
      before do
        allow(Rails.env).to receive(:production?).and_return(true)
      end

      after do
        allow(Rails.env).to receive(:production?).and_call_original
      end

      it "returns a stripe dashboard url" do
        expect(described_class.dashboard_url(account_id: "1234")).to eq("https://dashboard.stripe.com/1234/dashboard")
      end
    end

    describe "not production" do
      it "returns a stripe test dashboard url" do
        expect(described_class.dashboard_url(account_id: "1234")).to eq("https://dashboard.stripe.com/1234/test/dashboard")
      end
    end
  end

  describe "event_url" do
    describe "production" do
      before do
        allow(Rails.env).to receive(:production?).and_return(true)
      end

      after do
        allow(Rails.env).to receive(:production?).and_call_original
      end

      it "returns a stripe dashboard url" do
        expect(described_class.event_url("1234")).to eq("https://dashboard.stripe.com/events/1234")
      end
    end

    describe "not production" do
      it "returns a stripe test dashboard url" do
        expect(described_class.event_url("1234")).to eq("https://dashboard.stripe.com/test/events/1234")
      end
    end
  end

  describe "transfer_url" do
    describe "production" do
      before do
        allow(Rails.env).to receive(:production?).and_return(true)
      end

      after do
        allow(Rails.env).to receive(:production?).and_call_original
      end

      it "returns a connected-account payout url when account_id is provided" do
        expect(described_class.transfer_url("po_123", account_id: "acct_456"))
          .to eq("https://dashboard.stripe.com/connect/view-as/acct_456/payouts/po_123")
      end

      it "returns a platform payout url when account_id is not provided" do
        expect(described_class.transfer_url("po_123"))
          .to eq("https://dashboard.stripe.com/payouts/po_123")
      end
    end

    describe "not production" do
      it "returns a test-mode connected-account payout url when account_id is provided" do
        expect(described_class.transfer_url("po_123", account_id: "acct_456"))
          .to eq("https://dashboard.stripe.com/test/connect/view-as/acct_456/payouts/po_123")
      end

      it "returns a test-mode platform payout url when account_id is not provided" do
        expect(described_class.transfer_url("po_123"))
          .to eq("https://dashboard.stripe.com/test/payouts/po_123")
      end
    end
  end
end
