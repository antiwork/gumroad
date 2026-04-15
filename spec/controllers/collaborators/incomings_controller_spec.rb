# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/collaborators_base_controller_concern"
require "shared_examples/authentication_required"
require "inertia_rails/rspec"

describe Collaborators::IncomingsController, inertia: true do
  it_behaves_like "inherits from Collaborators::BaseController"

  let!(:seller1) { create(:user) }
  let!(:seller2) { create(:user) }
  let!(:seller3) { create(:user) }
  let!(:invited_user) { create(:user) }

  let!(:accepted_collaboration) do
    create(
      :collaborator,
      seller: seller2,
      affiliate_user: invited_user
    )
  end

  let!(:collaborator) { create(:collaborator, seller: seller3, affiliate_user: invited_user) }
  let!(:invitation) { create(:collaborator_invitation, collaborator: collaborator) }

  describe "GET index" do
    let!(:seller1_product) { create(:product, user: seller1) }
    let!(:seller2_product) { create(:product, user: seller2) }

    let!(:pending_collaboration) do
      create(
        :collaborator,
        :with_pending_invitation,
        seller: seller1,
        affiliate_user: invited_user,
      )
    end
    let!(:pending_collaboration_product) do
      create(:product_affiliate, affiliate: pending_collaboration, product: seller1_product)
    end

    let!(:accepted_collaboration_product) do
      create(:product_affiliate, affiliate: accepted_collaboration, product: seller2_product)
    end

    let!(:other_seller_pending_collaboration) do
      create(
        :collaborator,
        :with_pending_invitation,
        seller: seller1,
        affiliate_user: seller2
      )
    end

    before { sign_in invited_user }

    it_behaves_like "authentication required for action", :get, :index

    it_behaves_like "collaborator disabled reason sent", :get, :index

    it "returns the pending collaborations for the signed in user" do
      collaborator.destroy!
      get :index

      expect(response).to be_successful
      expect(inertia.component).to eq("Collaborators/Incomings/Index")
      expect(inertia.props[:title]).to eq("Collaborators")

      expect(inertia.props[:collaborators]).to eq(
        [
          {
            id: pending_collaboration.external_id,
            seller_email: seller1.email,
            seller_name: seller1.display_name(prefer_email_over_default_username: true),
            seller_avatar_url: seller1.avatar_url,
            apply_to_all_products: pending_collaboration.apply_to_all_products,
            percent_commission: pending_collaboration.affiliate_percentage,
            dont_show_as_co_creator: pending_collaboration.dont_show_as_co_creator,
            invitation_accepted: pending_collaboration.invitation_accepted?,
            products: [
              {
                id: seller1_product.external_id,
                url: seller1_product.long_url,
                name: seller1_product.name,
                percent_commission: pending_collaboration_product.affiliate_percentage,
              }
            ]
          },
          {
            id: accepted_collaboration.external_id,
            seller_email: seller2.email,
            seller_name: seller2.display_name(prefer_email_over_default_username: true),
            seller_avatar_url: seller2.avatar_url,
            apply_to_all_products: accepted_collaboration.apply_to_all_products,
            percent_commission: accepted_collaboration.affiliate_percentage,
            dont_show_as_co_creator: accepted_collaboration.dont_show_as_co_creator,
            invitation_accepted: accepted_collaboration.invitation_accepted?,
            products: [
              {
                id: seller2_product.external_id,
                url: seller2_product.long_url,
                name: seller2_product.name,
                percent_commission: accepted_collaboration_product.affiliate_percentage,
              }
            ]
          }
        ]
      )
      expect(inertia.props[:collaborators_disabled_reason]).to be_nil
    end
  end

  describe "POST accept" do
    it_behaves_like "authentication required for action", :post, :accept do
      let(:request_params) { { id: collaborator.external_id } }
    end

    context "when logged in as the invited user" do
      before { sign_in invited_user }

      it "accepts the invitation when found and redirects to collaborations page" do
        post :accept, params: { id: collaborator.external_id }

        expect(response).to be_redirect
        expect(response).to redirect_to(collaborators_incomings_path)
        expect(flash[:notice]).to eq("Invitation accepted")
        expect(collaborator.reload.invitation_accepted?).to eq(true)
      end

      context "when records are faulty" do
        include_examples "invalid collaborator records", :post, :accept
      end

      it "returns not found when there is no invitation" do
        invitation.destroy!
        expect { post :accept, params: { id: collaborator.external_id } }.to raise_error(ActionController::RoutingError)
      end
    end

    context "when logged in as a different user" do
      let(:different_user) { create(:user) }

      before { sign_in different_user }

      it "redirects when invitation isn't for the current user" do
        post :accept, params: { id: collaborator.external_id }

        expect(response).to redirect_to(dashboard_path)
        expect(flash[:alert]).to be_present
        expect(collaborator.reload.invitation_accepted?).to eq(false)
      end
    end
  end

  describe "POST decline" do
    it_behaves_like "authentication required for action", :post, :decline do
      let(:request_params) { { id: collaborator.external_id } }
    end

    context "when logged in as the invited user" do
      before { sign_in invited_user }

      it "soft-deletes the collaborator when found and redirects to collaborations page" do
        post :decline, params: { id: collaborator.external_id }

        expect(response).to be_redirect
        expect(response).to redirect_to(collaborators_incomings_path)
        expect(flash[:notice]).to eq("Invitation declined")
        expect(collaborator.reload.deleted?).to eq(true)
      end

      context "when records are faulty" do
        include_examples "invalid collaborator records", :post, :decline
      end

      it "returns not found when there is no invitation" do
        invitation.destroy!
        expect { post :decline, params: { id: collaborator.external_id } }.to raise_error(ActionController::RoutingError)
      end
    end

    context "when logged in as a different user" do
      let(:different_user) { create(:user) }

      before { sign_in different_user }

      it "redirects when invitation isn't for the current user" do
        post :decline, params: { id: collaborator.external_id }

        expect(response).to redirect_to(dashboard_path)
        expect(flash[:alert]).to be_present
        expect(collaborator.reload.deleted?).to eq(false)
      end
    end
  end

  describe "DELETE destroy" do
    before { sign_in invited_user }

    it_behaves_like "authentication required for action", :delete, :destroy do
      let(:request_params) { { id: accepted_collaboration.external_id } }
    end

    it "deletes the collaborator, sends the appropriate email, and redirects to the collaborations page" do
      expect do
        delete :destroy, params: { id: accepted_collaboration.external_id }
        expect(response).to be_redirect
        expect(response).to redirect_to(collaborators_incomings_path)
        expect(flash[:notice]).to eq("Collaborator removed")
      end.to have_enqueued_mail(AffiliateMailer, :collaboration_ended_by_affiliate_user).with(accepted_collaboration.id)

      expect(accepted_collaboration.reload.deleted_at).to be_present
    end

    context "when records are faulty" do
      include_examples "invalid collaborator records", :delete, :destroy
    end
  end
end
