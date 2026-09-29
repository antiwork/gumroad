# frozen_string_literal: true

require "spec_helper"

describe PingDelivery do
  describe "#as_props" do
    it "reports the HTTP status when the endpoint answered" do
      delivery = create(:ping_delivery, response_code: 403, succeeded: false)

      expect(delivery.as_props).to include(outcome: "HTTP 403", succeeded: false)
    end

    it "reports the error class when the request never completed" do
      delivery = create(:ping_delivery, response_code: nil, error_class: "SocketError", succeeded: false)

      expect(delivery.as_props).to include(outcome: "SocketError")
    end

    it "reports a missing response rather than a blank outcome" do
      delivery = create(:ping_delivery, response_code: nil, error_class: nil, succeeded: false)

      expect(delivery.as_props).to include(outcome: "No response")
    end

    it "carries the sale number, not the internal purchase id" do
      purchase = create(:free_purchase)
      delivery = create(:ping_delivery, purchase:, user: purchase.seller)

      expect(delivery.as_props[:sale_id]).to eq(purchase.external_id_numeric.to_s)
    end
  end

  describe ".recent" do
    it "returns the newest attempts first" do
      user = create(:user)
      older = create(:ping_delivery, user:, created_at: 2.hours.ago)
      newer = create(:ping_delivery, user:, created_at: 1.minute.ago)

      expect(user.ping_deliveries.recent.to_a).to eq([newer, older])
    end
  end
end
