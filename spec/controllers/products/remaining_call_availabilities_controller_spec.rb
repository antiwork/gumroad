# frozen_string_literal: true

require "spec_helper"

describe Products::RemainingCallAvailabilitiesController do
  describe "GET #index" do
    context "when the product is a call product" do
      let(:call_product) { create(:call_product) }
      let!(:call_availability) { create(:call_availability, call: call_product, start_time: 1.year.from_now, end_time: 1.year.from_now + 1.hour) }

      it "returns remaining call availabilities" do
        get :index, params: { product_id: call_product.unique_permalink }, as: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq(
          {
            "call_availabilities" => [
              {
                "start_time" => call_availability.start_time.in_time_zone(call_product.user.timezone).iso8601,
                "end_time" => call_availability.end_time.in_time_zone(call_product.user.timezone).iso8601
              }
            ]
          }
        )
      end
    end

    context "when the product is not a call product" do
      let(:not_call_product) { create(:coffee_product) }

      it "returns not found status" do
        get :index, params: { product_id: not_call_product.unique_permalink }, as: :json

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when the product does not exist" do
      it "raises a RecordNotFound error" do
        expect do
          get :index, params: { product_id: "non_existent_permalink" }, as: :json
        end.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
