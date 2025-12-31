# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Settings::TeamController, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", Settings::Team::UserPolicy do
    let(:record) { seller }
  end

  describe "GET show" do
    it "returns http success and renders Inertia component" do
      get :show

      expect(response).to be_successful
      expect(inertia.component).to eq("Settings/Team/Show")
      SettingsPresenter.new(pundit_user: controller.pundit_user)
      team_presenter = Settings::TeamPresenter.new(pundit_user: controller.pundit_user)
      expected_props = {
        member_infos: team_presenter.member_infos.map(&:to_hash),
        can_invite_member: Pundit.policy!(controller.pundit_user, [:settings, :team, TeamInvitation]).create?,
      }
      # Compare only the expected props from inertia.props (ignore shared props)
      actual_props = inertia.props.slice(*expected_props.keys)
      # Convert member_infos objects to hashes for comparison
      actual_props[:member_infos] = actual_props[:member_infos].map(&:to_hash) if actual_props[:member_infos]
      expect(actual_props).to eq(expected_props)
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

        expect(response).to redirect_to(settings_main_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to eq("Your Gumroad account doesn't have an email associated. Please assign and verify your email, and try again.")
      end
    end
  end
end
