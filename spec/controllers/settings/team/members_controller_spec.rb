# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::Team::MembersController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:policy_klass) { Settings::Team::UserPolicy }
      let(:policy_method) { :show? }
      let(:record) { seller }
      let(:request_format) { :json }
    end

    it "returns http success and assigns correct instance variables" do
      get :index, as: :json

      expect(response).to be_successful
      team_presenter = assigns[:team_presenter]
      expect(team_presenter.pundit_user).to eq(controller.pundit_user)
      expect(response.parsed_body["success"]).to eq(true)
      member_infos = team_presenter.member_infos.map(&:to_hash).map(&:stringify_keys!)
      member_infos.each do |member_info|
        member_info["options"].map(&:to_hash).map(&:stringify_keys!)
        member_info["leave_team_option"]&.stringify_keys!
      end
      expect(response.parsed_body["member_infos"]).to eq(member_infos)
    end
  end

  describe "PUT update" do
    let(:team_membership) { create(:team_membership, seller:, role: TeamMembership::ROLE_MARKETING) }

    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { Settings::Team::TeamMembershipPolicy }
      let(:record) { team_membership }
      let(:request_params) { { id: team_membership.external_id, team_membership: { role: TeamMembership::ROLE_ADMIN } } }
      let(:request_format) { :json }
    end

    it "updates role" do
      put :update, params: { id: team_membership.external_id, team_membership: { role: TeamMembership::ROLE_ADMIN } }, as: :json
      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(team_membership.reload.role_admin?).to eq(true)
    end
  end

  describe "DELETE destroy" do
    let(:user) { create(:user, is_team_member: true) }
    let(:team_membership) { create(:team_membership, seller:, user:) }

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:policy_klass) { Settings::Team::TeamMembershipPolicy }
      let(:record) { team_membership }
      let(:request_format) { :json }
      let(:request_params) { { id: team_membership.external_id } }
    end

    it "marks record as deleted" do
      delete :destroy, params: { id: team_membership.external_id }, as: :json
      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(user.reload.is_team_member).to eq(true)
      expect(team_membership.reload.deleted?).to eq(true)
    end

    context "with record belonging to other seller" do
      let(:team_membership) { create(:team_membership) }

      it "returns 404" do
        delete :destroy, params: { id: team_membership.external_id }, as: :json
        expect_404_response(response)
      end
    end

    context "when the seller is Gumroad" do
      let(:seller) { create(:named_seller, email: ApplicationMailer::ADMIN_EMAIL) }
      let(:team_membership) { create(:team_membership, seller:, user:) }

      it "removes the is_team_member flag from the user" do
        delete :destroy, params: { id: team_membership.external_id }, as: :json
        expect(user.reload.is_team_member).to eq(false)
      end
    end
  end

  describe "PATCH restore" do
    let(:team_membership) { create(:team_membership, seller:) }

    before do
      team_membership.update_as_deleted!
    end

    it_behaves_like "authorize called for action", :put, :restore do
      let(:policy_klass) { Settings::Team::TeamMembershipPolicy }
      let(:record) { team_membership }
      let(:request_format) { :json }
      let(:request_params) { { id: team_membership.external_id } }
    end

    it "marks record as not deleted" do
      put :restore, params: { id: team_membership.external_id }, as: :json
      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(team_membership.reload.deleted?).to eq(false)
    end

    context "with record belonging to other seller" do
      let(:team_membership) { create(:team_membership) }

      it "returns 404" do
        put :restore, params: { id: team_membership.external_id }, as: :json
        expect_404_response(response)
      end
    end
  end
end
