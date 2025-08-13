# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"

describe Api::Internal::Affiliates::InvitationCancelsController do
  let!(:seller) { create(:user) }
  let!(:invited_user) { create(:user) }
  let!(:affiliate) { create(:direct_affiliate, seller: seller, affiliate_user: invited_user) }
  let!(:invitation) { create(:affiliate_invitation, affiliate: affiliate) }

  describe "POST create" do
    it_behaves_like "authentication required for action", :post, :create do
      let(:request_params) { { affiliate_id: affiliate.external_id } }
    end

    context "when logged in as the seller" do
      before { sign_in seller }

      it "cancels the invitation when found" do
        post :create, params: { affiliate_id: affiliate.external_id }, format: :json

        expect(response).to have_http_status(:ok)
        expect { invitation.reload }.to raise_error(ActiveRecord::RecordNotFound)
        expect(affiliate.reload.deleted?).to be true
      end

      it "returns not found for non-existent affiliate" do
        expect do
          post :create, params: { affiliate_id: "non-existent-id" }, format: :json
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns not found when the affiliate has been soft-deleted" do
        affiliate.mark_deleted!

        expect do
          post :create, params: { affiliate_id: affiliate.external_id }, format: :json
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns not found when there is no invitation" do
        invitation.destroy!

        expect do
          post :create, params: { affiliate_id: affiliate.external_id }, format: :json
        end.to raise_error(ActionController::RoutingError)
      end

      it "prevents race conditions by rechecking invitation state" do
        # Simulate another process accepting the invitation
        allow(AffiliateInvitation).to receive(:lock).and_return(
          double("locked_invitation", find: invitation)
        )

        # Mock the affiliate to appear as if invitation was accepted
        locked_affiliate = double("locked_affiliate", invitation_pending?: false)
        allow(DirectAffiliate).to receive(:lock).and_return(
          double("locked_affiliate_class", find: locked_affiliate)
        )

        post :create, params: { affiliate_id: affiliate.external_id }, format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("Invitation has already been accepted or declined")
        expect(invitation.reload).to be_present
        expect(affiliate.reload.deleted?).to be false
      end

      it "uses row-level locking to prevent concurrent modifications" do
        expect(AffiliateInvitation).to receive(:lock).and_call_original
        expect(DirectAffiliate).to receive(:lock).and_call_original

        post :create, params: { affiliate_id: affiliate.external_id }, format: :json

        expect(response).to have_http_status(:ok)
      end
    end

    context "when logged in as a different user" do
      let(:different_user) { create(:user) }

      before { sign_in different_user }

      it "returns unauthorized when invitation isn't for the current user" do
        post :create, params: { affiliate_id: affiliate.external_id }, format: :json

        expect(response).to have_http_status(:unauthorized)
        expect(invitation.reload).to be_present
        expect(affiliate.reload.deleted?).to be false
      end
    end

    context "when logged in as the invited user" do
      before { sign_in invited_user }

      it "returns unauthorized when the invited user tries to cancel" do
        post :create, params: { affiliate_id: affiliate.external_id }, format: :json

        expect(response).to have_http_status(:unauthorized)
        expect(invitation.reload).to be_present
        expect(affiliate.reload.deleted?).to be false
      end
    end
  end
end
