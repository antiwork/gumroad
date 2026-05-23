# frozen_string_literal: true

require "test_helper"

class StripeUrlTest < ActiveSupport::TestCase
  self.described_class = StripeUrl



  context_ StripeUrl do
  context_ "dashboard_url" do
  context_ "production" do
        before do
          allow(Rails.env).to receive(:production?).and_return(true)
        end

        after do
          allow(Rails.env).to receive(:production?).and_call_original
        end

  test "returns a stripe dashboard url" do
          expect(described_class.dashboard_url(account_id: "1234")).to eq("https://dashboard.stripe.com/1234/dashboard")
        end
      end

  context_ "not production" do
  test "returns a stripe test dashboard url" do
          expect(described_class.dashboard_url(account_id: "1234")).to eq("https://dashboard.stripe.com/1234/test/dashboard")
        end
      end
    end

  context_ "event_url" do
  context_ "production" do
        before do
          allow(Rails.env).to receive(:production?).and_return(true)
        end

        after do
          allow(Rails.env).to receive(:production?).and_call_original
        end

  test "returns a stripe dashboard url" do
          expect(described_class.event_url("1234")).to eq("https://dashboard.stripe.com/events/1234")
        end
      end

  context_ "not production" do
  test "returns a stripe test dashboard url" do
          expect(described_class.event_url("1234")).to eq("https://dashboard.stripe.com/test/events/1234")
        end
      end
    end
  end
end
