# frozen_string_literal: true

require "spec_helper"

describe InstantPayoutsController do
  let(:seller) { create(:user) }
  let(:instant_payouts_service) { instance_double(InstantPayoutsService) }
  let(:date) { 1.day.ago.to_date }

  before do
    sign_in seller
    allow(InstantPayoutsService).to receive(:new).with(seller, date:).and_return(instant_payouts_service)
  end

  describe "#create" do
    context "when instant payout succeeds" do
      before do
        allow(instant_payouts_service).to receive(:perform).and_return({ success: true })
      end

      it "returns success" do
        post :create, params: { date: }
        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => true)
      end
    end

    context "when instant payout fails" do
      before do
        allow(instant_payouts_service).to receive(:perform).and_return(
          {
            success: false,
            error: "Error message"
          }
        )
      end

      it "returns error message" do
        post :create, params: { date: }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq(
          "success" => false,
          "error" => "Error message"
        )
      end
    end
  end
end
