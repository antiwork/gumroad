# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::TeamController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", Settings::Team::UserPolicy do
    let(:record) { seller }
  end

  describe "GET show" do
    it "returns http success and assigns correct instance variables" do
      get :show

      expect(response).to be_successful
      settings_presenter = assigns[:settings_presenter]
      expect(settings_presenter.pundit_user).to eq(controller.pundit_user)
      team_presenter = assigns[:team_presenter]
      expect(team_presenter.pundit_user).to eq(controller.pundit_user)
      react_component_props = assigns[:react_component_props]
      expect(react_component_props[:member_infos].map(&:to_hash)).to eq(team_presenter.member_infos.map(&:to_hash))
      expect(react_component_props[:settings_pages]).to eq(settings_presenter.pages)
    end

    context "when user does not have an email" do
      before do
        seller.update!(
          provider: :twitter,
          twitter_user_id: "123",
          email: nil
        )
      end

      it "redirects" do
        get :show

        expect(response).to redirect_to(settings_main_url)
        expect(flash[:alert]).to eq("Your Gumroad account doesn't have an email associated. Please assign and verify your email, and try again.")
      end
    end
  end
end
