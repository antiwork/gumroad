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
      expect(inertia.component).to eq("Workflows/New")
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

  describe "GET emails" do
    it_behaves_like "authorize called for action", :get, :emails do
      let(:record) { workflow }
      let(:request_params) { { id: workflow.external_id } }
    end

    it "renders successfully with Inertia" do
      get :emails, params: { id: workflow.external_id }
      expect(response).to be_successful
      expect(inertia.component).to eq("Workflows/Emails")
      expect(inertia.props[:workflow]).to be_present
      expect(inertia.props[:context]).to be_present
    end

    context "when workflow doesn't exist" do
      it "returns 404" do
        expect { get :emails, params: { id: "nonexistent" } }.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
