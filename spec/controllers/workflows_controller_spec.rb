# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"

describe WorkflowsController do
  it_behaves_like "inherits from Sellers::BaseController"

  render_views

  before do
    @user = create(:user)
    @product = create(:product, user: @user, price_cents: 0)
  end

  let(:seller) { @user }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Workflow }
    end

    it "renders successfully" do
      get :index
      expect(response).to be_successful
    end
  end
end
