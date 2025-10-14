# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe CollaboratorsController, inertia: true do
  render_views

  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:user) }

  describe "GET index" do
    before do
      sign_in seller
    end

    it "renders the index template" do
      get :index
      expect(response).to be_successful
      expect(inertia.component).to eq("Collaborators/Index")
      expect(inertia.props).to be_present
    end
  end
end
