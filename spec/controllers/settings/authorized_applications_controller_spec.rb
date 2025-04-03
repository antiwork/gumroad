# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::AuthorizedApplicationsController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  let(:pundit_user) { SellerContext.new(user: user_with_role_for_seller, seller:) }

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { OauthApplication }
      let(:policy_klass) { Settings::AuthorizedApplications::OauthApplicationPolicy }
    end

    it "returns http success and assigns correct instance variables" do
      create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "creator_api")
      get :index

      expect(response).to be_successful
      expect(assigns[:react_component_props]).to eq(SettingsPresenter.new(pundit_user:).authorized_applications_props)
    end
  end
end
