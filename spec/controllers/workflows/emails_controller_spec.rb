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

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { workflow }
      let(:request_params) { { workflow_id: workflow.external_id } }
    end

    it "renders successfully with Inertia" do
      get :index, params: { workflow_id: workflow.external_id }
      expect(response).to be_successful
      expect(inertia.component).to eq("Workflows/Emails/Index")
      expect(inertia.props[:workflow]).to be_present
      expect(inertia.props[:context]).to be_present
    end

    context "when workflow doesn't exist" do
      it "returns 404" do
        expect { get :index, params: { workflow_id: "nonexistent" } }.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "PATCH update" do
    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { workflow }
      let(:request_params) { { workflow_id: workflow.external_id, workflow: { send_to_past_customers: true, save_action_name: "save", installments: [] } } }
    end

    it "303 redirects to emails page with a success message" do
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
          installments: installment_params
        }
      }

      expect(response).to redirect_to(workflow_emails_path(workflow.external_id))
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq(Workflows::EmailsController::FLASH_CHANGES_SAVED)
    end

    it "redirects with published message when save_action_name is save_and_publish" do
      allow_any_instance_of(Workflow::SaveInstallmentsService).to receive(:process).and_return([true, nil])

      patch :update, params: {
        workflow_id: workflow.external_id,
        workflow: {
          send_to_past_customers: true,
          save_action_name: "save_and_publish",
          installments: []
        }
      }

      expect(response).to redirect_to(workflow_emails_path(workflow.external_id))
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq(Workflows::EmailsController::FLASH_WORKFLOW_PUBLISHED)
    end

    it "redirects with unpublished message when save_action_name is save_and_unpublish" do
      allow_any_instance_of(Workflow::SaveInstallmentsService).to receive(:process).and_return([true, nil])

      patch :update, params: {
        workflow_id: workflow.external_id,
        workflow: {
          send_to_past_customers: true,
          save_action_name: "save_and_unpublish",
          installments: []
        }
      }

      expect(response).to redirect_to(workflow_emails_path(workflow.external_id))
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq(Workflows::EmailsController::FLASH_WORKFLOW_UNPUBLISHED)
    end

    context "when save fails" do
      let(:errors) { workflow.errors.tap { |e| e.add(:base, "Installment message is required") } }

      before do
        allow_any_instance_of(Workflow::SaveInstallmentsService).to receive(:process).and_return([false, errors])
      end

      it "redirects with Inertia errors and specific alert message" do
        patch :update, params: {
          workflow_id: workflow.external_id,
          workflow: {
            send_to_past_customers: true,
            save_action_name: "save",
            installments: []
          }
        }

        expect(response).to redirect_to(workflow_emails_path(workflow.external_id))
        expect(flash[:alert]).to eq("Installment message is required")
        expect(session[:inertia_errors]).to be_present
      end
    end
  end
end
