# frozen_string_literal: true

class Settings::Team::InvitationsController < Sellers::BaseController
  include Throttling

  skip_before_action :require_account_email, only: :accept
  before_action :set_team_invitation, only: %i[update destroy restore resend_invitation]

  INVITATIONS_PER_HOUR = 10
  INVITATIONS_PER_DAY = 50
  INVITATION_BURST_REPORT_TTL = 24.hours

  def create
    authorize [:settings, :team, TeamInvitation]

    team_invitation = current_seller.team_invitations.new(create_params)
    team_invitation.expires_at = TeamInvitation::ACTIVE_INTERVAL_IN_DAYS.days.from_now.at_end_of_day

    # Counted only for an invitation that would really be sent, so a seller retrying a rejected
    # payload does not spend the account's own allowance.
    if team_invitation.valid?
      return unless throttle_invitation_sends
    end

    if team_invitation.save
      TeamMailer.invite(team_invitation).deliver_later
      render json: { success: true }
    else
      render json: { success: false, error_message: team_invitation.errors.full_messages.to_sentence }
    end
  end

  def update
    authorize [:settings, :team, @team_invitation]

    if @team_invitation.update(update_params)
      render json: { success: true }
    else
      render json: { success: false, error_message: @team_invitation.errors.full_messages.to_sentence }
    end
  end

  def destroy
    authorize [:settings, :team, @team_invitation]

    @team_invitation.update_as_deleted!
    render json: { success: true }
  end

  def restore
    authorize [:settings, :team, @team_invitation]

    @team_invitation.deleted_at = nil
    if @team_invitation.save
      render json: { success: true }
    else
      render json: { success: false, error_message: @team_invitation.errors.full_messages.to_sentence }
    end
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
    return unless throttle_invitation_sends

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

    # Sends rather than rows: `resend_invitation` re-mails without inserting, and a row-only cap would
    # leave an account's addresses blastable.
    def throttle_invitation_sends
      return true unless current_seller

      allowed = throttle_invitation_window("hour", INVITATIONS_PER_HOUR, 1.hour) &&
        throttle_invitation_window("day", INVITATIONS_PER_DAY, 24.hours)

      report_invitation_burst unless allowed
      allowed
    end

    # Hourly first, so a burst is cut off inside the hour rather than spending the day's allowance on
    # requests that were already refused.
    def throttle_invitation_window(name, limit, period)
      throttle!(
        key: RedisKey.team_invitation_send_throttle(current_seller.id, name),
        limit:,
        period:,
        message: ->(retry_after) { invitation_limit_message(name, limit, retry_after) }
      )
    end

    # Shown verbatim to the seller, so it names the real limit and wait; a non-positive countdown means
    # the window ended while Redis was answering, and promising a wait there would be false.
    def invitation_limit_message(name, limit, retry_after)
      return "You can invite again now." if retry_after <= 0

      unit, seconds = name == "day" ? ["hour", 1.hour] : ["minute", 1.minute]
      remaining = [(retry_after.to_f / seconds).ceil, 1].max
      "You've reached the limit of #{limit} team invitations per #{name}. " \
        "You can invite again in #{remaining} #{unit.pluralize(remaining)}."
    end

    # This runs on every attempt past the limit, so one report per account per day. The refusal is
    # already rendered: failing to report it must not turn a 429 into a 500.
    def report_invitation_burst
      return unless $redis.set(
        RedisKey.team_invitation_burst_reported(current_seller.id),
        1,
        nx: true,
        ex: INVITATION_BURST_REPORT_TTL.to_i
      )

      InternalNotificationWorker.perform_async(
        "risk",
        "Team invitations rate limited",
        "Seller #{current_seller.username || current_seller.external_id} (#{current_seller.email}) was " \
          "refused team invitations past #{INVITATIONS_PER_HOUR}/hour. Admin: #{current_seller.external_id}"
      )
    rescue => e
      ErrorNotifier.notify(e)
    end
end
