# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe CollaboratorsController, inertia: true do
  describe "GET index" do
    it "renders the index template" do
      get :index
      expect(response).to be_successful
      expect(inertia.component).to eq("Collaborators/Index")
      expect(inertia.props).to be_present
    end
  end
end
