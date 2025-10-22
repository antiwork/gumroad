# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"
require "inertia_rails/rspec"

describe Workflows::EmailsController, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:user) }
  let(:workflow) { create(:workflow, seller: seller) }

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { workflow }
      let(:request_params) { { workflow_id: workflow.external_id } }
    end

    it "renders successfully with Inertia" do
      get :show, params: { workflow_id: workflow.external_id }
      expect(response).to be_successful
      expect(inertia.component).to eq("Workflows/Emails")
      expect(inertia.props[:workflow]).to be_present
      expect(inertia.props[:context]).to be_present
    end

    context "when workflow doesn't exist" do
      it "returns 404" do
        expect { get :show, params: { workflow_id: "nonexistent" } }.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "PATCH update" do
    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { workflow }
      let(:request_params) { { workflow_id: workflow.external_id, workflow: { send_to_past_customers: true, save_action_name: "save", installments: "[]" } } }
    end

    it "redirects to emails page on success" do
      installment_params = [{
        id: "test-id",
        name: "Test Email",
        message: "<p>Test message</p>",
        time_period: "hour",
        time_duration: 1,
        send_preview_email: false,
        files: []
      }]

      patch :update, params: {
        workflow_id: workflow.external_id,
        workflow: {
          send_to_past_customers: true,
          save_action_name: "save",
          installments: installment_params.to_json
        }
      }

      expect(response).to redirect_to(workflow_emails_path(workflow.external_id))
    end

    context "when save fails" do
      before do
        allow_any_instance_of(Workflow::SaveInstallmentsService).to receive(:process).and_return([false, "Error message"])
      end

      it "redirects with alert" do
        patch :update, params: {
          workflow_id: workflow.external_id,
          workflow: {
            send_to_past_customers: true,
            save_action_name: "save",
            installments: "[]"
          }
        }

        expect(response).to redirect_to(workflow_emails_path(workflow.external_id))
        expect(flash[:alert]).to eq("Error message")
      end
    end
  end
end
