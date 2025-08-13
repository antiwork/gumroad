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
        expect(affiliate.reload.deleted?).to eq(true)
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

      it "returns unprocessable entity when invitation is no longer pending (race condition)" do
        # Simulate the invitation no longer being pending (e.g., accepted elsewhere)
        allow_any_instance_of(AffiliateInvitation).to receive(:pending?).and_return(false)

        post :create, params: { affiliate_id: affiliate.external_id }, format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to have_key("errors")
        expect(invitation.reload).to be_present
        expect(affiliate.reload.deleted?).to eq(false)
      end

      it "uses row-level locking to prevent race conditions" do
        expect_any_instance_of(AffiliateInvitation).to receive(:with_lock).and_call_original

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
        expect(affiliate.reload.deleted?).to eq(false)
      end
    end

    context "when logged in as the invited user" do
      before { sign_in invited_user }

      it "returns unauthorized when the invited user tries to cancel" do
        post :create, params: { affiliate_id: affiliate.external_id }, format: :json

        expect(response).to have_http_status(:unauthorized)
        expect(invitation.reload).to be_present
        expect(affiliate.reload.deleted?).to eq(false)
      end
    end
  end
end
