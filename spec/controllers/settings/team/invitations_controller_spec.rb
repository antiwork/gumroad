# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::Team::InvitationsController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:policy_klass) { Settings::Team::TeamInvitationPolicy }
      let(:record) { TeamInvitation }
      let(:request_params) { { email: "", role: nil } }
      let(:request_format) { :json }
    end

    context "when payload is valid" do
      it "creates team invitation record" do
        allow(TeamMailer).to receive(:invite).and_call_original
        expect do
          post :create, params: { team_invitation: { email: "member@example.com", role: "admin" } }, as: :json
        end.to change { seller.team_invitations.count }.by(1)
        expect(TeamMailer).to have_received(:invite).with(TeamInvitation.last)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(true)

        team_invitation = seller.team_invitations.last
        expect(team_invitation.email).to eq("member@example.com")
        expect(team_invitation.role_admin?).to eq(true)
        expect(team_invitation.expires_at).not_to be(nil)
      end
    end

    context "when payload is not valid" do
      it "returns error" do
        allow(TeamMailer).to receive(:invite)
        expect do
          post :create, params: { team_invitation: { email: "", role: "" } }, as: :json
        end.not_to change { seller.team_invitations.count }
        expect(TeamMailer).not_to have_received(:invite)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error_message"]).to eq("Email is invalid and Role is not included in the list")
      end
    end

    context "when invitation sends are limited" do
      def post_invitation(email)
        post :create, params: { team_invitation: { email:, role: "admin" } }, as: :json
      end

      def enqueued_invitation_emails
        ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:args].first == "TeamMailer" }
      end

      it "refuses the eleventh send without creating an invitation or enqueueing an email" do
        expect do
          10.times { |index| post_invitation("member#{index}@example.com") }
        end.to change { enqueued_invitation_emails }.by(10)

        expect(TeamMailer).not_to receive(:invite)
        expect do
          post_invitation("one-too-many@example.com")
        end.to not_change { seller.team_invitations.count }
          .and not_change { enqueued_invitation_emails }

        expect(response).to have_http_status(:too_many_requests)
        expect(response.parsed_body["error"]).to match(/limit of 10 team invitations per hour/)
        expect(response.parsed_body["retry_after"]).to be_between(1, 3600)
        expect(response.headers["Retry-After"].to_i).to eq(response.parsed_body["retry_after"])
      end

      it "refuses sends past the daily limit and reports the daily restriction" do
        key = RedisKey.team_invitation_send_throttle(seller.id)
        50.times { |index| $redis.zadd(key, 2.hours.ago.to_f, index.to_s) }

        expect(TeamMailer).not_to receive(:invite)
        expect(InternalNotificationWorker).to receive(:perform_async)
          .with("risk", "Team invitations rate limited", /past 50\/day/).once
        expect do
          post_invitation("one-too-many@example.com")
        end.to not_change { seller.team_invitations.count }
          .and not_change { enqueued_invitation_emails }

        expect(response).to have_http_status(:too_many_requests)
        expect(response.parsed_body["error"]).to include("limit of 50 team invitations per day")
        expect(response.parsed_body["retry_after"]).to be > 21.hours.to_i
      end

      it "reports the first refusal once and preserves the response if reporting fails" do
        10.times { TeamInvitationThrottle.check(seller.id) }
        expect(InternalNotificationWorker).to receive(:perform_async).once.and_raise(StandardError, "unavailable")
        expect(ErrorNotifier).to receive(:notify).with(instance_of(StandardError))

        3.times do
          post_invitation("overflow@example.com")
          expect(response).to have_http_status(:too_many_requests)
        end
      end

      it "does not reserve sends for invalid or duplicate invitations" do
        post_invitation("member@example.com")
        key = RedisKey.team_invitation_send_throttle(seller.id)

        expect do
          10.times do
            ["not-an-email", "member@example.com", seller.email].each do |email|
              post_invitation(email)
              expect(response.parsed_body["success"]).to eq(false)
            end
          end
        end.not_to change { $redis.zcard(key) }

        post_invitation("teammate@example.com")
        expect(response.parsed_body["success"]).to eq(true)
      end

      it "does not let another seller's sends block this seller" do
        other_seller = create(:user)
        10.times { TeamInvitationThrottle.check(other_seller.id) }

        expect do
          3.times { |index| post_invitation("teammate#{index}@example.com") }
        end.to change { seller.team_invitations.count }.by(3)
        expect(response.parsed_body["success"]).to eq(true)
      end
    end
  end

  describe "PUT update" do
    let(:team_invitation) { create(:team_invitation, seller:, role: TeamMembership::ROLE_MARKETING) }

    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { Settings::Team::TeamInvitationPolicy }
      let(:record) { team_invitation }
      let(:request_params) { { id: team_invitation.external_id, team_invitation: { role: TeamMembership::ROLE_ADMIN } } }
      let(:request_format) { :json }
    end

    it "updates role" do
      put :update, params: { id: team_invitation.external_id, team_invitation: { role: TeamMembership::ROLE_ADMIN } }, as: :json
      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(team_invitation.reload.role_admin?).to eq(true)
    end

    context "when the invitation email belongs to an existing team member" do
      before do
        member = create(:user, email: team_invitation.email)
        create(:team_membership, seller:, user: member)
      end

      it "returns an error instead of raising an exception" do
        put :update, params: { id: team_invitation.external_id, team_invitation: { role: TeamMembership::ROLE_ADMIN } }, as: :json
        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error_message"]).to eq("Email is associated with an existing team member")
        expect(team_invitation.reload.role_marketing?).to eq(true)
      end
    end
  end

  describe "DELETE destroy" do
    let(:team_invitation) { create(:team_invitation, seller:) }

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:policy_klass) { Settings::Team::TeamInvitationPolicy }
      let(:record) { team_invitation }
      let(:request_format) { :json }
      let(:request_params) { { id: team_invitation.external_id } }
    end

    it "updates record as deleted" do
      delete :destroy, params: { id: team_invitation.external_id }, as: :json
      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(team_invitation.reload.deleted?).to eq(true)
    end

    context "with record belonging to other seller" do
      let(:team_invitation) { create(:team_invitation) }

      it "returns 404" do
        delete :destroy, params: { id: team_invitation.external_id }, as: :json
        expect_404_response(response)
      end
    end
  end

  describe "PUT restore" do
    let(:team_invitation) { create(:team_invitation, seller:) }

    before do
      team_invitation.update_as_deleted!
    end

    it_behaves_like "authorize called for action", :put, :restore do
      let(:policy_klass) { Settings::Team::TeamInvitationPolicy }
      let(:record) { team_invitation }
      let(:request_format) { :json }
      let(:request_params) { { id: team_invitation.external_id } }
    end

    it "updates record as deleted" do
      put :restore, params: { id: team_invitation.external_id }, as: :json
      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(team_invitation.reload.deleted?).to eq(false)
    end

    context "when the email is associated with an existing team member" do
      before do
        member = create(:user, email: team_invitation.email)
        member.create_owner_membership_if_needed!
        create(:team_membership, seller: seller, user: member)
      end

      it "returns an error" do
        put :restore, params: { id: team_invitation.external_id }, as: :json
        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error_message"]).to include("existing team member")
        expect(team_invitation.reload.deleted?).to eq(true)
      end
    end

    context "with record belonging to other seller" do
      let(:team_invitation) { create(:team_invitation) }

      it "returns 404" do
        put :restore, params: { id: team_invitation.external_id }, as: :json
        expect_404_response(response)
      end
    end
  end

  describe "GET accept" do
    let(:email) { "Member@example.com" }
    let(:user) { create(:named_user, email:) }
    let(:team_invitation) { create(:team_invitation, seller:, email: user.email) }

    before do
      sign_in(user)
    end

    it_behaves_like "authorize called for action", :get, :accept do
      let(:policy_klass) { Settings::Team::TeamInvitationPolicy }
      let(:record) { team_invitation }
      let(:request_params) { { id: team_invitation.external_id } }
    end

    it "successfully accepts the invitation" do
      allow(TeamMailer).to receive(:invitation_accepted).and_call_original

      expect do
        get :accept, params: { id: team_invitation.external_id }
      end.to change { seller.seller_memberships.count }

      expect(team_invitation.reload.accepted?).to eq(true)
      expect(team_invitation.deleted?).to eq(true)

      expect(user.user_memberships.count).to eq(2)
      owner_membership = user.user_memberships.first
      expect(owner_membership.role).to eq(TeamMembership::ROLE_OWNER)
      seller_membership = user.user_memberships.last
      expect(user.reload.is_team_member).to eq(false)
      expect(seller_membership.role).to eq(team_invitation.role)
      expect(TeamMailer).to have_received(:invitation_accepted).with(TeamMembership.last)

      expect(cookies.encrypted[:current_seller_id]). to eq(seller.id)
      expect(response).to redirect_to(dashboard_url)
      expect(flash[:notice]).to eq("Welcome to the team at seller!")
    end

    context "when the seller is Gumroad" do
      let(:seller) { create(:named_seller, email: ApplicationMailer::ADMIN_EMAIL) }

      before { team_invitation.update!(seller:) }

      it "sets the user's is_team_member flag to true" do
        expect do
          get :accept, params: { id: team_invitation.external_id }
        end.to change { seller.seller_memberships.count }

        expect(user.reload.is_team_member).to eq(true)
      end
    end

    context "when logged-in user email is missing" do
      let(:team_invitation) { create(:team_invitation, seller:, email:) }

      before do
        user.update_attribute(:email, nil)
      end

      it "renders email missing alert" do
        expect do
          get :accept, params: { id: team_invitation.external_id }
        end.not_to change { seller.seller_memberships.count }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Your Gumroad account doesn't have an email associated. Please assign and verify your email before accepting the invitation.")
      end
    end

    context "when logged-in user email is not confirmed" do
      before { user.update!(confirmed_at: nil) }

      it "renders unconfirmed email alert" do
        expect do
          get :accept, params: { id: team_invitation.external_id }
        end.not_to change { seller.seller_memberships.count }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Please confirm your email address before accepting the invitation.")
      end
    end

    context "when logged-in user email is different" do
      before { team_invitation.update!(email: "wrong.email@example.com") }

      it "renders email mismatch alert" do
        expect do
          get :accept, params: { id: team_invitation.external_id }
        end.not_to change { seller.seller_memberships.count }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("The invite was sent to a different email address. You are logged in as member@example.com")
      end
    end

    context "when invitation has expired" do
      before { team_invitation.update!(expires_at: 1.second.ago) }

      it "renders expired invitation alert" do
        expect do
          get :accept, params: { id: team_invitation.external_id }
        end.not_to change { seller.seller_memberships.count }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Invitation link has expired. Please contact the account owner.")
      end
    end

    context "when the invitation has already been accepted" do
      before { team_invitation.update_as_accepted! }

      it "renders invitation already accepted alert" do
        expect do
          get :accept, params: { id: team_invitation.external_id }
        end.not_to change { seller.seller_memberships.count }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Invitation has already been accepted.")
      end
    end

    context "when the invitation has been deleted" do
      before { team_invitation.update_as_deleted! }

      it "renders invitation already accepted alert" do
        expect do
          get :accept, params: { id: team_invitation.external_id }
        end.not_to change { seller.seller_memberships.count }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Invitation link is invalid. Please contact the account owner.")
      end
    end

    context "when the invitation email matches the owner's email" do
      before do
        # Edge case when the seller changes their email to the same email used for the invitation
        team_invitation.update_attribute(:email, seller.email)
        sign_in(seller)
      end

      it "deletes the invitation and renders invitation invalid alert" do
        expect do
          get :accept, params: { id: team_invitation.external_id }
        end.not_to change { seller.seller_memberships.count }

        expect(team_invitation.reload.deleted?).to eq(true)
        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Invitation link is invalid. Please contact the account owner.")
      end
    end
  end

  describe "PUT resend_invitation" do
    let(:team_invitation) { create(:team_invitation, seller:, expires_at: 1.year.ago) }

    it_behaves_like "authorize called for action", :put, :resend_invitation do
      let(:policy_klass) { Settings::Team::TeamInvitationPolicy }
      let(:record) { team_invitation }
      let(:request_format) { :json }
      let(:request_params) { { id: team_invitation.external_id } }
    end

    it "updates team invitation record and enqueues email" do
      allow(TeamMailer).to receive(:invite).and_call_original
      put :resend_invitation, params: { id: team_invitation.external_id }, as: :json
      expect(TeamMailer).to have_received(:invite).with(team_invitation)

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)

      expect(team_invitation.reload.expires_at).to be_within(1.second).of(
        TeamInvitation::ACTIVE_INTERVAL_IN_DAYS.days.from_now.at_end_of_day
      )
    end

    it "shares the send allowance with new invitations and refuses resends without changing expiry" do
      10.times do |index|
        post :create, params: { team_invitation: { email: "new#{index}@example.com", role: "admin" } }, as: :json
      end

      expect(TeamMailer).not_to receive(:invite)
      expect do
        put :resend_invitation, params: { id: team_invitation.external_id }, as: :json
      end.to not_change { team_invitation.reload.expires_at }
        .and not_change { ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:args].first == "TeamMailer" } }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["error"]).to include("limit of 10 team invitations per hour")
    end
  end
end
