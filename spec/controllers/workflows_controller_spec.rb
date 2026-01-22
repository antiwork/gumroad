# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"
require "inertia_rails/rspec"

describe WorkflowsController, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:user) }
  let(:workflow) { create(:workflow, seller: seller) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Workflow }
    end

    it "renders successfully with Inertia" do
      get :index
      expect(response).to be_successful
      expect(inertia.component).to eq("Workflows/Index")
      expect(inertia.props[:workflows]).to be_an(Array)
    end
  end

  describe "GET new" do
    it_behaves_like "authorize called for action", :get, :new do
      let(:record) { Workflow }
    end

    it "renders successfully with Inertia" do
      get :new
      expect(response).to be_successful
      expect(inertia).to render_component("Workflows/New")
      expect(inertia.props[:context]).to be_present
    end
  end

  describe "GET edit" do
    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { workflow }
      let(:request_params) { { id: workflow.external_id } }
    end

    it "renders successfully with Inertia" do
      get :edit, params: { id: workflow.external_id }
      expect(response).to be_successful
      expect(inertia.component).to eq("Workflows/Edit")
      expect(inertia.props[:workflow]).to be_present
      expect(inertia.props[:context]).to be_present
    end

    context "when workflow doesn't exist" do
      it "returns 404" do
        expect { get :edit, params: { id: "nonexistent" } }.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { Workflow }
      let(:request_params) { { workflow: { name: "Test Workflow", workflow_type: "audience" } } }
    end

    context "with valid params" do
      it "303 redirects to workflow emails page with a success message" do
        post :create, params: { workflow: { name: "Test Workflow", workflow_type: "audience" } }

        expect(response).to redirect_to(workflow_emails_path(Workflow.last.external_id))
        expect(response).to have_http_status(:see_other)
        expect(flash[:notice]).to eq("Changes saved!")
      end
    end

    context "with invalid params" do
      it "redirects back to new workflow page with errors when service fails" do
        allow_any_instance_of(Workflow::ManageService).to receive(:process).and_return([false, "Name can't be blank"])

        post :create, params: { workflow: { name: "", workflow_type: "audience" } }

        expect(response).to redirect_to(new_workflow_path)
        expect(response.status).to eq(302)
      end

      it "handles validation errors from the service" do
        workflow_params = { name: "Test", workflow_type: "audience" }
        service = instance_double(Workflow::ManageService)

        allow(Workflow::ManageService).to receive(:new).and_return(service)
        allow(service).to receive(:process).and_return([false, "Validation failed"])

        post :create, params: { workflow: workflow_params }

        expect(response).to redirect_to(new_workflow_path)
      end
    end

    context "with abandoned cart workflow" do
      it "returns error when seller is not eligible for abandoned cart workflows" do
        allow_any_instance_of(User).to receive(:eligible_for_abandoned_cart_workflows?).and_return(false)

        post :create, params: { workflow: { name: "Cart Workflow", workflow_type: "abandoned_cart" } }

        expect(response).to redirect_to(new_workflow_path)
      end
    end
  end

  describe "PATCH update" do
    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { workflow }
      let(:request_params) { { id: workflow.external_id, workflow: { name: "Updated Workflow" } } }
    end

    context "with valid params" do
      it "303 redirects to workflow emails page with a success message" do
        patch :update, params: { id: workflow.external_id, workflow: { name: "Updated Workflow" } }

        expect(response).to redirect_to(workflow_emails_path(workflow.external_id))
        expect(response).to have_http_status(:see_other)
        expect(flash[:notice]).to eq("Changes saved!")
      end

      it "redirects to workflow emails page with publish message when save_and_publish" do
        # Mark workflow as published previously so it can be published again
        workflow.update_columns(first_published_at: 1.day.ago, published_at: nil)
        # Ensure seller is eligible to send emails
        allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)

        patch :update, params: { id: workflow.external_id, workflow: { name: "Updated Workflow", save_action_name: "save_and_publish" } }

        expect(response).to redirect_to(workflow_emails_path(workflow.external_id))
        expect(response).to have_http_status(:see_other)
        expect(flash[:notice]).to eq("Workflow published!")
      end

      it "redirects to workflow emails page with unpublish message when save_and_unpublish" do
        patch :update, params: { id: workflow.external_id, workflow: { name: "Updated Workflow", save_action_name: "save_and_unpublish" } }

        expect(response).to redirect_to(workflow_emails_path(workflow.external_id))
        expect(response).to have_http_status(:see_other)
        expect(flash[:notice]).to eq("Unpublished!")
      end
    end

    context "with invalid params" do
      it "redirects back to edit workflow page with errors when service fails" do
        allow_any_instance_of(Workflow::ManageService).to receive(:process).and_return([false, "Name can't be blank"])

        patch :update, params: { id: workflow.external_id, workflow: { name: "" } }

        expect(response).to redirect_to(edit_workflow_path(workflow.external_id))
        expect(flash[:alert]).to eq("Name can't be blank")
      end

      it "handles validation errors from the service" do
        service = instance_double(Workflow::ManageService)

        allow(Workflow::ManageService).to receive(:new).and_return(service)
        allow(service).to receive(:process).and_return([false, "Validation failed"])

        patch :update, params: { id: workflow.external_id, workflow: { name: "Test" } }

        expect(response).to redirect_to(edit_workflow_path(workflow.external_id))
        expect(flash[:alert]).to eq("Validation failed")
      end

      it "handles ActiveRecord::RecordInvalid errors" do
        allow_any_instance_of(Workflow::ManageService).to receive(:process).and_raise(ActiveRecord::RecordInvalid.new(workflow))

        expect do
          patch :update, params: { id: workflow.external_id, workflow: { name: "Test" } }
        end.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context "when workflow doesn't exist" do
      it "returns 404" do
        expect do
          patch :update, params: { id: "nonexistent", workflow: { name: "Test" } }
        end.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "DELETE destroy" do
    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { workflow }
      let(:request_params) { { id: workflow.external_id } }
    end

    it "303 redirects to workflows page with a success message" do
      delete :destroy, params: { id: workflow.external_id }

      expect(response).to redirect_to(workflows_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Workflow deleted!")
      expect(workflow.reload.deleted_at).to be_present
    end
  end
end
