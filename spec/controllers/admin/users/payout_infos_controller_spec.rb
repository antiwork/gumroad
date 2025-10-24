# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Users::PayoutInfosController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:user) { create(:user) }

  before do
    sign_in admin_user
  end

  describe "GET 'show'" do
    it "returns the user's payout info as JSON" do
      get :show, params: { user_id: user.id }, format: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include("active_bank_account" => nil)
    end
  end
end
