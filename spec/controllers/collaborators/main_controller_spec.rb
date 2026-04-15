# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/collaborators_base_controller_concern"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"
require "inertia_rails/rspec"

describe Collaborators::MainController, type: :controller, inertia: true do
  it_behaves_like "inherits from Collaborators::BaseController"

  let(:seller) { create(:user) }
  let!(:product) { create(:product, user: seller) }

  before do
    sign_in seller
  end

  describe "GET index" do
    it_behaves_like "authentication required for action", :get, :index

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Collaborator }
    end

    it_behaves_like "collaborator disabled reason sent", :get, :index

    it "renders the index template with correct props" do
      collaborator1 = create(:collaborator, seller:, products: [create(:product, user: seller)])
      collaborator2 = create(:collaborator, seller:)

      get :index

      expect(response).to be_successful
      expect(inertia.component).to eq("Collaborators/Index")
      expect(inertia.props[:title]).to eq("Collaborators")

      expected_collaborators = [collaborator1, collaborator2].map do
        CollaboratorPresenter.new(seller:, collaborator: _1).collaborator_props
      end

      expect(inertia).to include_props(
        collaborators: expected_collaborators,
        has_incoming_collaborators: false
      )
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

    it_behaves_like "collaborator disabled reason sent", :get, :edit do
      let(:request_params) { { id: collaborator.external_id } }
    end

    it "renders the edit template with correct props" do
      get :edit, params: { id: collaborator.external_id }

      expect(response).to be_successful
      expect(inertia.component).to eq("Collaborators/Edit")
      expect(inertia.props[:title]).to eq("Collaborators")

      presenter = CollaboratorPresenter.new(seller:, collaborator:)
      expected_props = presenter.edit_collaborator_props
      actual_props = inertia.props.slice(*expected_props.keys)
      expect(actual_props).to eq(expected_props)
    end

    context "when records are faulty" do
      include_examples "invalid collaborator records", :get, :edit
    end
  end

  describe "GET new" do
    it_behaves_like "authentication required for action", :get, :new

    it_behaves_like "authorize called for action", :get, :new do
      let(:record) { Collaborator }
    end

    it_behaves_like "collaborator disabled reason sent", :get, :new

    it "renders the new template with correct props" do
      get :new

      expect(response).to be_successful
      expect(inertia.component).to eq("Collaborators/New")
      expect(inertia.props[:title]).to eq("Collaborators")

      presenter = CollaboratorPresenter.new(seller:)
      expected_props = presenter.new_collaborator_props
      actual_props = inertia.props.slice(*expected_props.keys)
      expect(actual_props).to eq(expected_props)
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

    it "creates a collaborator and redirects" do
      expect do
        post :create, params: params
        expect(response).to redirect_to(collaborators_path)
        expect(flash[:notice]).to eq("Changes saved!")
      end.to change { seller.collaborators.count }.from(0).to(1)
         .and change { ProductAffiliate.count }.from(0).to(1)
    end

    it "redirects to new collaborator page with errors when creation fails" do
      params[:collaborator][:percent_commission] = 90

      post :create, params: params

      expect(response).to be_redirect
      expect(response).to redirect_to(new_collaborator_path)
      get :new
      expect(inertia.component).to eq("Collaborators/New")
      expect(flash[:alert]).to eq("Product affiliates affiliate basis points must be less than or equal to 5000")
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

    it "deletes the collaborator, sends the appropriate email, and redirects to the collaborators page" do
      expect do
        delete :destroy, params: { id: collaborator.external_id }
        expect(response).to be_redirect
        expect(response).to redirect_to(collaborators_path)
        expect(flash[:notice]).to eq("The collaborator was removed successfully.")
      end.to have_enqueued_mail(AffiliateMailer, :collaboration_ended_by_seller).with(collaborator.id)

      expect(collaborator.reload.deleted_at).to be_present
    end

    context "when records are faulty" do
      include_examples "invalid collaborator records", :delete, :destroy
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

    it "updates a collaborator and redirects to collaborators page" do
      expect do
        patch :update, params: params
        expect(response).to be_redirect
        expect(response).to redirect_to(collaborators_path)
        expect(flash[:notice]).to eq("Changes saved!")
      end.to change { collaborator.products.count }.from(1).to(2)

      collaborator.reload
      expect(collaborator.apply_to_all_products).to eq false
      expect(collaborator.products).to match_array [product2, product3]
      expect(collaborator.product_affiliates.find_by(product: product2).affiliate_basis_points).to eq 40_00
      expect(collaborator.product_affiliates.find_by(product: product3).affiliate_basis_points).to eq 50_00
    end

    it "redirects to edit collaborator page with errors when update fails" do
      collaborator.errors.add(:base, "an error")
      allow_any_instance_of(Collaborator::UpdateService).to receive(:process).and_return({ success: false, collaborator: })

      patch :update, params: params

      expect(response).to be_redirect
      expect(response).to redirect_to(edit_collaborator_path(collaborator.external_id))
      get :edit, params: { id: collaborator.external_id }
      expect(inertia.component).to eq("Collaborators/Edit")
      expect(flash[:alert]).to eq("an error")
    end

    it "redirects to edit collaborator page with errors when percent_commission is invalid" do
      params[:collaborator][:apply_to_all_products] = true
      params[:collaborator][:percent_commission] = 90
      params[:collaborator][:products] = [{ id: product2.external_id }]

      patch :update, params: params

      expect(response).to be_redirect
      expect(response).to redirect_to(edit_collaborator_path(collaborator.external_id))
      get :edit, params: { id: collaborator.external_id }
      expect(inertia.component).to eq("Collaborators/Edit")
      expect(flash[:alert]).to eq("Product affiliates affiliate basis points must be less than or equal to 5000")
    end


    context "when records are faulty" do
      include_examples "invalid collaborator records", :patch, :update
    end
  end
end
