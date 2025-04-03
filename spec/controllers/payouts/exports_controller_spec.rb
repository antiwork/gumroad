# frozen_string_literal: true

require "spec_helper"

RSpec.describe Payouts::ExportsController, type: :controller do
  let(:seller) { create(:named_seller) }

  before do
    sign_in seller
  end

  describe "POST #create" do
    context "when no parameters are provided" do
      it "returns unprocessable entity" do
        post :create, format: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("Invalid payouts")
      end
    end

    context "when invalid parameters are provided" do
      it "returns unprocessable entity" do
        post :create, params: { payment_ids: ["invalid_id"] }, format: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("Invalid payouts")

        post :create, params: { payment_ids: [] }, format: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("Invalid payouts")

        post :create, params: { payment_ids: "invalid_id" }, format: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("Invalid payouts")
      end
    end

    context "when valid parameters are provided" do
      let!(:payouts) { create_list(:payment_completed, 2, user: seller) }

      it "queues a job with the expected parameters" do
        expect do
          post :create, params: { payout_ids: payouts.map(&:external_id) }, format: :json
        end.to change(ExportPayoutData.jobs, :size).by(1)

        expect(response).to have_http_status(:ok)

        job = ExportPayoutData.jobs.last
        expect(job["args"][0]).to match_array(payouts.map(&:id))
        expect(job["args"][1]).to eq(seller.id)
      end
    end

    context "when a payout ID for a different seller is provided" do
      let(:other_seller) { create(:user) }
      let(:other_seller_payout) { create(:payment_completed, user: other_seller) }

      it "fails with unprocessable entity" do
        expect do
          post :create, params: { payout_ids: [other_seller_payout.external_id] }, format: :json
        end.not_to change(ExportPayoutData.jobs, :size)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("Invalid payouts")
      end
    end
  end
end
