# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"

describe Workflows::InstallmentsController, type: :controller do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:user) }
  let(:workflow) { create(:workflow, seller: seller) }

  include_context "with user signed in as admin for seller"

  describe "PATCH update" do
    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { workflow }
      let(:request_params) { { workflow_id: workflow.external_id, workflow: { save_action_name: "save_and_publish" } } }
    end

    context "with valid params" do
      it "updates installments and redirects" do
        patch :update, params: { workflow_id: workflow.external_id, workflow: { save_action_name: "save_and_publish" } }
        expect(response).to redirect_to(workflow_emails_path(workflow.external_id))
        expect(flash[:notice]).to eq("Installments saved successfully!")
      end
    end

    context "when workflow doesn't exist" do
      it "returns 404" do
        expect { patch :update, params: { workflow_id: "nonexistent", workflow: { save_action_name: "save_and_publish" } } }.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
