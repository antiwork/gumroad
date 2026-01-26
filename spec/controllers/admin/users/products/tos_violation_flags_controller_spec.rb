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
      get :index, params: { user_external_id: user.external_id, product_external_id: product.external_id }
      expect(response).to be_successful

      payload = response.parsed_body
      expect(payload["tos_violation_flags"]).to eq(tos_violation_flags.as_json(only: %i[id content]))
    end

    context "when the user is not flagged for TOS violation" do
      let(:user_risk_state) { :compliant }

      it "returns an empty array" do
        get :index, params: { user_external_id: user.external_id, product_external_id: product.external_id }
        expect(response).to be_successful
        expect(response.parsed_body["tos_violation_flags"]).to eq([])
      end
    end
  end

  describe "POST create" do
    let(:user_risk_state) { :compliant }
    let(:suspend_tos_params) { { suspend_tos: { reason: "Spam content" } } }

    context "when the user can be flagged for TOS violation" do
      before do
        allow_any_instance_of(User).to receive(:can_flag_for_tos_violation?).and_return(true)
      end

      it "flags the user for TOS violation and returns success" do
        expect do
          post :create, params: { user_external_id: user.external_id, product_external_id: product.external_id }.merge(suspend_tos_params)
        end.to change { user.reload.tos_violation_reason }.from(nil).to("Spam content")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be true
      end

      it "creates a comment for the TOS violation flag" do
        expect do
          post :create, params: { user_external_id: user.external_id, product_external_id: product.external_id }.merge(suspend_tos_params)
        end.to change { Comment.count }.by(2)

        comment = Comment.where(commentable: user).last
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_FLAGGED)
        expect(comment.content).to include("Flagged for a policy violation")
        expect(comment.content).to include(product.name)
        expect(comment.content).to include("Spam content")

        comment = Comment.where(commentable: product).last
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_FLAGGED)
        expect(comment.content).to include("Flagged for a policy violation")
        expect(comment.content).to include(product.name)
        expect(comment.content).to include("Spam content")
      end

      context "when the product is a tiered membership" do
        let(:product) { create(:product, user:, is_tiered_membership: true) }

        it "unpublishes the product" do
          expect do
            post :create, params: { user_external_id: user.external_id, product_external_id: product.external_id }.merge(suspend_tos_params)
          end.to change { product.reload.published? }.from(true).to(false)
        end
      end

      context "when the product is not a tiered membership" do
        let(:product) { create(:product, user:, is_tiered_membership: false) }

        it "deletes the product" do
          expect do
            post :create, params: { user_external_id: user.external_id, product_external_id: product.external_id }.merge(suspend_tos_params)
          end.to change { product.reload.deleted? }.from(false).to(true)
        end
      end
    end

    context "when the user cannot be flagged for TOS violation" do
      before do
        allow_any_instance_of(User).to receive(:can_flag_for_tos_violation?).and_return(false)
      end

      it "returns an error" do
        post :create, params: { user_external_id: user.external_id, product_external_id: product.external_id }.merge(suspend_tos_params)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["error_message"]).to eq("Cannot flag for TOS violation")
      end
    end

    context "when the reason is blank" do
      let(:suspend_tos_params) { { suspend_tos: { reason: "" } } }

      it "returns an error" do
        post :create, params: { user_external_id: user.external_id, product_external_id: product.external_id }.merge(suspend_tos_params)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["error_message"]).to eq("Invalid request")
      end
    end
  end
end
