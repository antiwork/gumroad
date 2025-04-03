# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe UtmLinksController do
  let(:seller) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  include_context "with user signed in as admin for seller"

  before do
    Feature.activate_user(:utm_links, seller)
  end

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { UtmLink }
    end

    it "returns unauthorized response if the :utm_links feature flag is disabled" do
      Feature.deactivate_user(:utm_links, seller)

      get :index

      expect(response).to redirect_to dashboard_path
      expect(flash[:alert]).to eq("Your current role as Admin cannot perform this action.")
    end

    it "renders the page" do
      get :index
      expect(response).to be_successful
    end
  end
end
