# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"

describe Api::Internal::Collaborators::InvitationAcceptancesController do
  let!(:seller) { create(:user) }
  let!(:invited_user) { create(:user) }
  let!(:collaborator) { create(:collaborator, seller: seller, affiliate_user: invited_user) }
  let!(:invitation) { create(:collaborator_invitation, collaborator: collaborator) }

  describe "POST create" do
    it_behaves_like "authentication required for action", :post, :create do
      let(:request_params) { { collaborator_id: collaborator.external_id } }
    end

    context "when logged in as the invited user" do
      before { sign_in invited_user }

      it "accepts the invitation when found" do
        post :create, params: { collaborator_id: collaborator.external_id }, format: :json

        expect(response).to have_http_status(:ok)
        expect(collaborator.reload.invitation_accepted?).to eq(true)
      end

      it "returns not found for non-existent collaborator" do
        expect do
          post :create, params: { collaborator_id: "non-existent-id" }, format: :json
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns not found when the collaborator has been soft-deleted" do
        collaborator.mark_deleted!

        expect do
          post :create, params: { collaborator_id: collaborator.external_id }, format: :json
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns not found when there is no invitation" do
        invitation.destroy!

        expect do
          post :create, params: { collaborator_id: collaborator.external_id }, format: :json
        end.to raise_error(ActionController::RoutingError)
      end
    end

    context "when logged in as a different user" do
      let(:different_user) { create(:user) }

      before { sign_in different_user }

      it "returns unauthorized when invitation isn't for the current user" do
        post :create, params: { collaborator_id: collaborator.external_id }, format: :json

        expect(response).to have_http_status(:unauthorized)
        expect(collaborator.reload.invitation_accepted?).to eq(false)
      end
    end
  end
end
