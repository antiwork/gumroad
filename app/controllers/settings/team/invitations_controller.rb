# frozen_string_literal: true

class Settings::Team::InvitationsController < Sellers::BaseController
  before_action :set_team_invitation, only: %i[update destroy restore resend_invitation]

  def create
    authorize [:settings, :team, TeamInvitation]

    team_invitation = current_seller.team_invitations.new(create_params)
    team_invitation.expires_at = TeamInvitation::ACTIVE_INTERVAL_IN_DAYS.days.from_now.at_end_of_day

    if team_invitation.save
      TeamMailer.invite(team_invitation).deliver_later
      render json: { success: true }
    else
      render json: { success: false, error_message: team_invitation.errors.full_messages.to_sentence }
    end
  end

  def update
    authorize [:settings, :team, @team_invitation]

    @team_invitation.update!(update_params)
    render json: { success: true }
  end

  def destroy
    authorize [:settings, :team, @team_invitation]

    @team_invitation.update_as_deleted!
    render json: { success: true }
  end

  def restore
    authorize [:settings, :team, @team_invitation]

    @team_invitation.update_as_not_deleted!
    render json: { success: true }
  end

  def accept
    team_invitation = TeamInvitation.find_by_external_id!(external_team_invitation_id)
    authorize [:settings, :team, team_invitation]

    alert_message = nil
    logged_in_user_email = logged_in_user.email&.downcase
    if logged_in_user_email.blank?
      alert_message = "Your Gumroad account doesn't have an email associated. Please assign and verify your email before accepting the invitation."
    elsif !logged_in_user.confirmed?
      alert_message = "Please confirm your email address before accepting the invitation."
    elsif team_invitation.email != logged_in_user_email
      alert_message = "The invite was sent to a different email address. You are logged in as #{logged_in_user_email}"
    elsif team_invitation.expired?
      alert_message = "Invitation link has expired. Please contact the account owner."
    elsif team_invitation.accepted?
      alert_message = "Invitation has already been accepted."
    elsif team_invitation.deleted?
      alert_message = "Invitation link is invalid. Please contact the account owner."
    elsif team_invitation.matches_owner_email?
      # It can happen if the owner sends an invitation, and then changes their email address to the same email used
      # for the invitation. When the invitation is accepted, the membership cannot be created because the email is already
      # taken by the owner. In this case, the invitation is deleted and the user is redirected to the seller's account.
      team_invitation.update_as_deleted!
      alert_message = "Invitation link is invalid. Please contact the account owner."
    end

    if alert_message.present?
      flash[:alert] = alert_message
    else
      team_membership = nil
      logged_in_user.with_lock do
        team_invitation.update_as_accepted!(deleted_at: Time.current)
        logged_in_user.create_owner_membership_if_needed!
        logged_in_user.update!(is_team_member: true) if team_invitation.from_gumroad_account?
        team_membership = team_invitation.seller.seller_memberships.create!(user: logged_in_user, role: team_invitation.role)
        TeamMailer.invitation_accepted(team_membership).deliver_later
      end

      switch_seller_account(team_membership)
      flash[:notice] = "Welcome to the team at #{team_membership.seller.username}!"
    end

    redirect_to dashboard_url
  end

  def resend_invitation
    authorize [:settings, :team, @team_invitation]

    @team_invitation.update!(
      expires_at: TeamInvitation::ACTIVE_INTERVAL_IN_DAYS.days.from_now.at_end_of_day
    )

    TeamMailer.invite(@team_invitation).deliver_later
    render json: { success: true }
  end

  private
    def create_params
      params.require(:team_invitation).permit(:email, :role)
    end

    def update_params
      params.require(:team_invitation).permit(:role)
    end

    def set_team_invitation
      @team_invitation = current_seller.team_invitations.find_by_external_id(params[:id]) || e404_json
    end

    def external_team_invitation_id
      params.require(:id)
    end
end
