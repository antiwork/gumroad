# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Users::Products::TosViolationFlagsController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:user_risk_state) { :flagged_for_tos_violation }
  let(:user) { create(:user, user_risk_state:) }
  let(:product) { create(:product, user:) }
  let(:tos_violation_flags) { create_list(:comment, 2, commentable: product, comment_type: Comment::COMMENT_TYPE_FLAGGED) }

  before do
    tos_violation_flags
    sign_in admin_user
  end

  describe "GET index" do
    it "returns a JSON payload with the tos violation flags" do
      get :index, params: { user_id: user.id, product_id: product.id }
      expect(response).to be_successful

      payload = response.parsed_body
      expect(payload["tos_violation_flags"]).to eq(tos_violation_flags.as_json(only: %i[id content]))
    end

    context "when the user is not flagged for TOS violation" do
      let(:user_risk_state) { :compliant }

      it "returns a JSON payload with the error message" do
        get :index, params: { user_id: user.id, product_id: product.id }
        expect(response).to be_bad_request
        expect(response.parsed_body["error"]).to eq("User is not flagged for TOS violation")
      end
    end
  end
end
