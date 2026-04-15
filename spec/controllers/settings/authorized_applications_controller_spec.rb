# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Settings::AuthorizedApplicationsController, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  let(:pundit_user) { SellerContext.new(user: user_with_role_for_seller, seller:) }

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { OauthApplication }
      let(:policy_klass) { Settings::AuthorizedApplications::OauthApplicationPolicy }
    end

    it "returns http success and renders Inertia component" do
      create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "creator_api")
      get :index

      expect(response).to be_successful
      expect(inertia.component).to eq("Settings/AuthorizedApplications/Index")
      pundit_user = SellerContext.new(user: user_with_role_for_seller, seller:)
      expected_props = SettingsPresenter.new(pundit_user:).authorized_applications_props
      actual_props = inertia.props.slice(*expected_props.keys)
      expect(actual_props).to eq(expected_props)
    end
  end
end
