# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::TaxDocumentsController do
  let(:seller) { create(:user, created_at: 2.years.ago) }

  include_context "with user signed in as admin for seller"

  before do
    Feature.activate_user(:tax_center, seller)
  end

  describe "GET index" do
    it_behaves_like "authentication required for action", :get, :index

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { :balance }
    end

    context "when tax_center feature is enabled" do
      it "returns tax center data for the current year when no year is provided" do
        travel_to Time.new(2024, 6, 15) do
          create(:user_tax_form, user: seller, tax_year: 2024, tax_form_type: "us_1099_k")

          get :index, format: :json

          expect(response).to be_successful
          expect(response.parsed_body.deep_symbolize_keys).to match(TaxCenterPresenter.new(seller:, year: 2024).props)
        end
      end

      it "returns tax center data for a specific year when provided" do
        create(:user_tax_form, user: seller, tax_year: 2023, tax_form_type: "us_1099_k")

        get :index, params: { year: 2023 }, format: :json

        expect(response).to be_successful
        expect(response.parsed_body.deep_symbolize_keys).to match(TaxCenterPresenter.new(seller:, year: 2023).props)
      end
    end

    context "when tax_center feature is disabled" do
      before do
        Feature.deactivate_user(:tax_center, seller)
      end

      it "returns unauthorized error" do
        get :index, format: :json

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body).to eq({ "success" => false, "error" => "Tax center is not enabled for your account." })
      end
    end
  end
end
