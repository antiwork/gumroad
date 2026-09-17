# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::Team::InvitationsController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  %w[suspended_for_fraud suspended_for_tos_violation].each do |state|
    context "when the seller is #{state}" do
      before { seller.update!(user_risk_state: state) }

      it "refuses an active admin's new invitations for the suspended seller" do
        expect do
          post :create, params: { team_invitation: { email: "member@example.com", role: "admin" } }, as: :json
        end.to not_change { seller.team_invitations.count }
          .and not_change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }
          .and not_change { $redis.zcard(RedisKey.team_invitation_send_throttle(seller.id)) }

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body["success"]).to eq(false)
      end

      it "refuses an active admin's resends without extending expiry" do
        invitation = create(:team_invitation, seller:, expires_at: 1.day.ago)
        expect do
          put :resend_invitation, params: { id: invitation.external_id }, as: :json
        end.to not_change { invitation.reload.expires_at }
          .and not_change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body["success"]).to eq(false)
      end
    end
  end

  %w[suspended_for_fraud suspended_for_tos_violation deleted].each do |state|
    it "refuses new and resend requests by a #{state} owner" do
      invitation = create(:team_invitation, seller:, expires_at: 1.day.ago)
      seller.update!(state == "deleted" ? { deleted_at: Time.current } : { user_risk_state: state })
      sign_in seller

      expect do
        post :create, params: { team_invitation: { email: "member@example.com", role: "admin" } }, as: :json
        expect(response.parsed_body["success"]).to eq(false)
        put :resend_invitation, params: { id: invitation.external_id }, as: :json
        expect(response.parsed_body["success"]).to eq(false)
      end.to not_change { seller.team_invitations.count }
        .and not_change { invitation.reload.expires_at }
        .and not_change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }
    end
  end

  it "does not resend for a deleted seller through an active admin's stale account cookie" do
    invitation = create(:team_invitation, seller:)
    seller.update!(deleted_at: Time.current)

    expect do
      put :resend_invitation, params: { id: invitation.external_id }, as: :json
    end.not_to change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }

    expect_404_response(response)
    expect(controller.current_seller).to eq(user_with_role_for_seller)
  end

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

    it "creates an invitation for a quoted local-part mailbox" do
      email = '"member,one"@example.com'

      expect do
        post :create, params: { team_invitation: { email:, role: "admin" } }, as: :json
      end.to change { seller.team_invitations.count }.by(1)
        .and change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }.by(1)

      expect(response.parsed_body["success"]).to eq(true)
      expect(seller.team_invitations.last.email).to eq(email)
    end

    [
      '"Synthetic notice" <member@example.com>, "sink"@example.net',
      '"member"@"sink"@example.com'
    ].each do |email|
      it "refuses a non-mailbox #{email.inspect} without reserving a send" do
        expect do
          post :create, params: { team_invitation: { email:, role: "admin" } }, as: :json
        end.to not_change { seller.team_invitations.count }
          .and not_change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }
          .and not_change { $redis.zcard(RedisKey.team_invitation_send_throttle(seller.id)) }

        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => false, "error_message" => "Email is invalid")
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
      # The per-window allowance is for reviewed sellers; an unreviewed one hits the total cap below first.
      let(:seller) { create(:named_seller, user_risk_state: "compliant") }

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

    # Every account in the 62-account relay ring (gp#2762) was `not_reviewed` with zero products. A real new team
    # is one or two people, so an unreviewed seller gets a small fixed total and the per-window allowance waits
    # for review.
    context "when the seller has not been reviewed" do
      def post_invitation(email)
        post :create, params: { team_invitation: { email:, role: "admin" } }, as: :json
      end

      it "allows the total cap and then refuses without creating an invitation or enqueueing an email" do
        expect(seller.user_risk_state).to eq("not_reviewed")

        expect do
          TeamInvitationThrottle::UNREVIEWED_TOTAL_LIMIT.times { |index| post_invitation("member#{index}@example.com") }
        end.to change { seller.team_invitations.count }.by(TeamInvitationThrottle::UNREVIEWED_TOTAL_LIMIT)
        expect(response.parsed_body["success"]).to eq(true)

        expect(TeamMailer).not_to receive(:invite)
        expect(InternalNotificationWorker).to receive(:perform_async)
          .with("risk", "Team invitations rate limited", /past #{TeamInvitationThrottle::UNREVIEWED_TOTAL_LIMIT}\/account/o).once
        expect do
          post_invitation("one-too-many@example.com")
        end.not_to change { seller.team_invitations.count }

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error_message"]).to include("up to #{TeamInvitationThrottle::UNREVIEWED_TOTAL_LIMIT} team invitations while the account is being reviewed")
      end

      it "counts revoked invitations toward the cap" do
        TeamInvitationThrottle::UNREVIEWED_TOTAL_LIMIT.times { |index| post_invitation("member#{index}@example.com") }
        seller.team_invitations.each(&:update_as_deleted!)

        expect do
          post_invitation("recycled@example.com")
        end.not_to change { seller.team_invitations.count }
        expect(response.parsed_body["success"]).to eq(false)
      end

      it "does not cap a seller who was marked compliant" do
        seller.update!(user_risk_state: "compliant")

        expect do
          (TeamInvitationThrottle::UNREVIEWED_TOTAL_LIMIT + 1).times { |index| post_invitation("member#{index}@example.com") }
        end.to change { seller.team_invitations.count }.by(TeamInvitationThrottle::UNREVIEWED_TOTAL_LIMIT + 1)
      end
    end

    context "when the seller is suspended" do
      before { seller.update_column(:user_risk_state, "suspended_for_tos_violation") }

      it "refuses without creating an invitation or enqueueing an email" do
        expect(TeamMailer).not_to receive(:invite)
        expect do
          post :create, params: { team_invitation: { email: "member@example.com", role: "admin" } }, as: :json
        end.not_to change { seller.team_invitations.count }

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body["error_message"]).to eq("Your account can't send team invitations right now.")
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

    it "allows deleting a legacy invitation with a recipient list" do
      team_invitation.update_columns(email: '"Synthetic notice" <member@example.com>, "sink"@example.net')

      delete :destroy, params: { id: team_invitation.external_id }, as: :json

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(team_invitation.reload).to be_deleted
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

    %w[suspended_for_fraud suspended_for_tos_violation deleted].each do |state|
      it "does not accept an invitation from a #{state} seller" do
        team_invitation
        seller.update!(state == "deleted" ? { deleted_at: Time.current } : { user_risk_state: state })

        expect do
          get :accept, params: { id: team_invitation.external_id }
        end.to not_change { seller.seller_memberships.count }
          .and not_change { team_invitation.reload.accepted_at }
          .and not_change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Invitation link is invalid. Please contact the account owner.")
      end
    end

    it "re-checks the seller inside the acceptance transaction, not when the link is read" do
      invitation = team_invitation
      # Suspend the seller after the eligibility check has passed but before the transaction body,
      # which is the window the check would otherwise leave open.
      allow(User).to receive(:transaction).and_wrap_original do |original, *args, &block|
        User.where(id: seller.id).update_all(user_risk_state: "suspended_for_fraud", updated_at: Time.current)
        original.call(*args, &block)
      end

      expect do
        get :accept, params: { id: invitation.external_id }
      end.to not_change { seller.seller_memberships.count }
        .and not_change { user.user_memberships.count }
        .and not_change { invitation.reload.accepted_at }

      expect(flash[:alert]).to eq("Invitation link is invalid. Please contact the account owner.")
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

    [
      '"Synthetic notice" <member@example.com>, "sink"@example.net',
      '"member"@"sink"@example.com'
    ].each do |email|
      it "refuses resending a legacy non-mailbox #{email.inspect} without extending expiry" do
        team_invitation.update_columns(email:)

        expect do
          put :resend_invitation, params: { id: team_invitation.external_id }, as: :json
        end.to not_change { team_invitation.reload.expires_at }
          .and not_change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }
          .and not_change { $redis.zcard(RedisKey.team_invitation_send_throttle(seller.id)) }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq("success" => false, "error_message" => "Email is invalid")
      end
    end

    it "shares the send allowance with new invitations and refuses resends without changing expiry" do
      seller.update!(user_risk_state: "compliant")
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

    it "refuses resends from a suspended seller without extending expiry" do
      seller.update_column(:user_risk_state, "suspended_for_tos_violation")

      expect(TeamMailer).not_to receive(:invite)
      expect do
        put :resend_invitation, params: { id: team_invitation.external_id }, as: :json
      end.not_to change { team_invitation.reload.expires_at }

      expect(response).to have_http_status(:forbidden)
    end
  end
end

describe Settings::Team::InvitationsController, "reciprocal acceptance" do
  # Worker connections need committed fixtures; cleanup is scoped to these two users.
  self.use_transactional_tests = false

  before do
    Rails.application.routes_reloader.execute_unless_loaded
    @users = 2.times.map { |index| create(:user, email: "reciprocal#{index}@example.com") }
    @invitations = @users.each_with_index.map do |user, index|
      create(:team_invitation, seller: @users[1 - index], email: user.email)
    end
  end

  after do
    user_ids = @users.map(&:id)
    TeamInvitation.where(seller_id: user_ids).delete_all
    TeamMembership.where(user_id: user_ids).or(TeamMembership.where(seller_id: user_ids)).delete_all
    Affiliate.where(affiliate_user_id: user_ids).delete_all
    RefundPolicy.where(seller_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
  end

  it "accepts both invitations while the reciprocal request waits on a user row lock" do
    enqueued_jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
    first_lock = Queue.new
    release_first = Queue.new
    second_connection_id = Queue.new
    results = Queue.new
    errors = Queue.new
    first_request = nil
    second_request = nil

    # Pause after the first locking query until the reciprocal request reaches a real MySQL lock wait.
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:first_reciprocal_acceptance]
      next unless payload[:sql].include?("FROM `users`") && payload[:sql].include?("FOR UPDATE")

      Thread.current[:first_reciprocal_acceptance] = false
      first_lock << true
      release_first.pop
    end

    first_request = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:first_reciprocal_acceptance] = true
        results << accept_invitation(@users.first, @invitations.first)
      rescue StandardError => error
        errors << error
      ensure
        Thread.current[:first_reciprocal_acceptance] = false
        first_lock << true
      end
    end
    Timeout.timeout(10) { first_lock.pop }
    raise errors.pop unless errors.empty?

    second_request = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        second_connection_id << connection.select_value("SELECT CONNECTION_ID()")
        results << accept_invitation(@users.last, @invitations.last)
      rescue StandardError => error
        errors << error
      end
    end
    process_id = Timeout.timeout(10) { second_connection_id.pop }
    Timeout.timeout(10) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
          SELECT COUNT(*)
          FROM performance_schema.data_lock_waits AS lock_waits
          INNER JOIN performance_schema.data_locks AS requested_lock
            ON requested_lock.ENGINE_LOCK_ID = lock_waits.REQUESTING_ENGINE_LOCK_ID
          INNER JOIN performance_schema.threads AS requesting_thread
            ON requesting_thread.THREAD_ID = lock_waits.REQUESTING_THREAD_ID
          WHERE requesting_thread.PROCESSLIST_ID = #{process_id.to_i}
            AND requested_lock.OBJECT_SCHEMA = DATABASE()
            AND requested_lock.OBJECT_NAME = 'users'
        SQL
        break if waiting.to_i.positive?

        sleep 0.01
      end
    end

    expect(results).to be_empty
    release_first << true
    [first_request, second_request].each { expect(_1.join(10)).to be_present }

    raise errors.pop unless errors.empty?
    expect(results.size).to eq(2)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.drop(enqueued_jobs_before).map { |job| job[:args].first(2) }).to eq(
      [["TeamMailer", "invitation_accepted"], ["TeamMailer", "invitation_accepted"]]
    )
    2.times do
      status, notice = results.pop
      expect(status).to eq(302)
      expect(notice).to start_with("Welcome to the team at ")
    end
    @invitations.each do |invitation|
      expect(invitation.reload).to be_accepted
      expect(invitation).to be_deleted
    end
    @users.each_with_index do |user, index|
      expect(user.user_memberships.pluck(:seller_id, :role)).to contain_exactly(
        [user.id, TeamMembership::ROLE_OWNER],
        [@users[1 - index].id, @invitations[index].role]
      )
      expect(user.reload.is_team_member).to eq(false)
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_first << true
    [first_request, second_request].compact.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end

  def accept_invitation(user, invitation)
    request = ActionController::TestRequest.create(described_class)
    request.host = DOMAIN
    request.env["devise.mapping"] = Devise.mappings[:user]
    request.env["warden"] = Warden::Proxy.new(request.env, Warden::Manager.new(nil) { |config| config.merge!(Devise.warden_config) })
    request.env["warden"].set_user(User.find(user.id), scope: :user, store: false, run_callbacks: false)
    request.set_header("REQUEST_METHOD", "GET")
    request.path_parameters = { controller: "settings/team/invitations", action: "accept", id: invitation.external_id }
    controller = described_class.new
    controller.set_request!(request)
    controller.set_response!(ActionDispatch::TestResponse.new)
    controller.process(:accept)
    [controller.response.status, controller.flash[:notice]]
  end
end
