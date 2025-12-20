# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Settings::RefundFundingController do
  let(:seller) { create(:user) }

  include_context "with user signed in as admin for seller"

  describe "GET #show" do
    it_behaves_like "authentication required for action", :get, :show

    context "when no funding card is configured" do
      it "returns enabled as false" do
        get :show, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["enabled"]).to be false
        expect(json["credit_card"]).to be_nil
      end
    end
  end

  describe "DELETE #destroy" do
    it_behaves_like "authentication required for action", :delete, :destroy
  end
end
