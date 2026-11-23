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

      it "redirects to balance path with success notice" do
        post :create, params: { date: }
        expect(response).to redirect_to(balance_path)
        expect(flash[:notice]).to eq("Instant payout initiated successfully")
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

      it "redirects to balance path with error alert" do
        post :create, params: { date: }
        expect(response).to redirect_to(balance_path)
        expect(flash[:alert]).to eq("Error message")
      end
    end

    context "when the date param is not a plain date string" do
      it "rejects a nested date param without raising" do
        expect(InstantPayoutsService).not_to receive(:new)

        post :create, params: { date: { "x" => "2026-11-24" } }

        expect(response).to redirect_to(balance_path)
        expect(flash[:alert]).to eq("Invalid date")
      end

      it "rejects an array date param without raising" do
        expect(InstantPayoutsService).not_to receive(:new)

        post :create, params: { date: ["2026-11-24"] }

        expect(response).to redirect_to(balance_path)
        expect(flash[:alert]).to eq("Invalid date")
      end

      it "rejects an unparseable date string" do
        expect(InstantPayoutsService).not_to receive(:new)

        post :create, params: { date: "not-a-date" }

        expect(response).to redirect_to(balance_path)
        expect(flash[:alert]).to eq("Invalid date")
      end
    end
  end
end
