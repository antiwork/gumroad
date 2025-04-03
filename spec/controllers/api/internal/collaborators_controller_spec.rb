# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::CollaboratorsController do
  let(:seller) { create(:user) }
  let!(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authentication required for action", :get, :index

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Collaborator }
    end

    it "returns the seller's collaborators" do
      create(:collaborator, seller:, products: [create(:product, user: seller)])
      create(:collaborator, seller:)

      get :index, format: :json
      expect(response).to be_successful
      expect(response.parsed_body.deep_symbolize_keys).to match(CollaboratorsPresenter.new(seller:).index_props)
    end
  end

  describe "GET edit" do
    let!(:collaborator) { create(:collaborator, seller:, products: [create(:product, user: seller)]) }

    it_behaves_like "authentication required for action", :get, :edit do
      let(:request_params) { { id: collaborator.external_id } }
    end

    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { collaborator }
      let(:request_params) { { id: collaborator.external_id } }
    end

    it "successfully returns the collaborator when found" do
      get :edit, params: { id: collaborator.external_id }, format: :json

      expect(response).to be_successful
      expect(response.parsed_body).to match(CollaboratorPresenter.new(seller:, collaborator:).edit_collaborator_props.as_json)
    end

    it "raises an e404 if the collaborator is not found" do
      expect do
        get :edit, params: { id: "non-existent-id" }, format: :json
      end.to raise_error(ActionController::RoutingError)
    end
  end

  describe "GET new" do
    it_behaves_like "authentication required for action", :get, :new

    it_behaves_like "authorize called for action", :get, :new do
      let(:record) { Collaborator }
    end

    it "returns data needed for creating a new collaborator" do
      get :new, format: :json
      expect(response).to be_successful
      expect(response.parsed_body).to match(CollaboratorPresenter.new(seller:).new_collaborator_props.as_json)
    end
  end

  describe "POST create" do
    it_behaves_like "authentication required for action", :post, :create

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { Collaborator }
    end

    let(:collaborating_user) { create(:user) }
    let(:params) do
      {
        collaborator: {
          email: collaborating_user.email,
          apply_to_all_products: true,
          percent_commission: 30,
          products: [{ id: product.external_id }],
        }
      }
    end

    it "creates a collaborator" do
      expect do
        post :create, params:, format: :json
        expect(response).to have_http_status(:created)
        expect(response.parsed_body.symbolize_keys).to match({ success: true })
      end.to change { seller.collaborators.count }.from(0).to(1)
         .and change { ProductAffiliate.count }.from(0).to(1)
    end

    it "returns an error with invalid params" do
      params[:collaborator][:percent_commission] = 90
      post :create, params:, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.symbolize_keys).to match({
                                                             success: false,
                                                             message: "Product affiliates affiliate basis points must be less than or equal to 5000"
                                                           })
    end
  end

  describe "DELETE destroy" do
    let!(:collaborator) { create(:collaborator, seller:, products: [product]) }

    it_behaves_like "authentication required for action", :delete, :destroy do
      let(:request_params) { { id: collaborator.external_id } }
    end

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { collaborator }
      let(:request_params) { { id: collaborator.external_id } }
    end

    it "deletes the collaborator" do
      expect do
        delete :destroy, params: { id: collaborator.external_id }, format: :json
      end.to have_enqueued_mail(AffiliateMailer, :collaboration_ended_by_seller).with(collaborator.id)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("")

      expect(collaborator.reload.deleted_at).to be_present
    end

    context "when affiliate user is deleting the collaboration" do
      let(:affiliate_user) { collaborator.affiliate_user }

      before do
        sign_in(affiliate_user)
      end

      it "deletes the collaborator and sends the appropriate email" do
        expect do
          delete :destroy, params: { id: collaborator.external_id }, format: :json
        end.to have_enqueued_mail(AffiliateMailer, :collaboration_ended_by_affiliate_user).with(collaborator.id)

        expect(response).to be_successful
        expect(collaborator.reload.deleted_at).to be_present
      end
    end

    context "collaborator is not found" do
      it "returns an error" do
        expect do
          delete :destroy, params: { id: "fake" }, format: :json
        end.to raise_error(ActionController::RoutingError)
      end
    end

    context "collaborator is soft deleted" do
      it "returns an error" do
        collaborator.mark_deleted!
        expect do
          delete :destroy, params: { id: collaborator.external_id }, format: :json
        end.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "PATCH update" do
    let(:product1) { create(:product, user: seller) }
    let!(:product2) { create(:product, user: seller) }
    let!(:product3) { create(:product, user: seller) }
    let(:collaborator) { create(:collaborator, apply_to_all_products: true, affiliate_basis_points: 30_00, seller:) }
    let(:params) do
      {
        id: collaborator.external_id,
        collaborator: {
          apply_to_all_products: false,
          products: [
            { id: product2.external_id, percent_commission: 40 },
            { id: product3.external_id, percent_commission: 50 },
          ],
        },
      }
    end

    before do
      create(:product_affiliate, affiliate: collaborator, product: product1, affiliate_basis_points: 30_00)
    end

    it_behaves_like "authentication required for action", :patch, :update do
      let(:request_params) { { id: collaborator.external_id } }
    end

    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { collaborator }
      let(:request_params) { { id: collaborator.external_id } }
    end

    it "updates a collaborator" do
      expect do
        patch :update, params:, format: :json
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.symbolize_keys).to match({ success: true })
      end.to change { collaborator.products.count }.from(1).to(2)

      collaborator.reload
      expect(collaborator.apply_to_all_products).to eq false
      expect(collaborator.products).to match_array [product2, product3]
      expect(collaborator.product_affiliates.find_by(product: product2).affiliate_basis_points).to eq 40_00
      expect(collaborator.product_affiliates.find_by(product: product3).affiliate_basis_points).to eq 50_00
    end

    it "returns a 422 if there is an error updating the collaborator" do
      allow_any_instance_of(Collaborator::UpdateService).to receive(:process).and_return({ success: false, message: "an error" })

      patch :update, params:, format: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.deep_symbolize_keys).to match({ success: false, message: "an error" })
    end

    context "collaborator is soft deleted" do
      it "returns an error" do
        collaborator.mark_deleted!
        expect do
          patch :update, params:, format: :json
        end.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
