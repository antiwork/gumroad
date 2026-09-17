# frozen_string_literal: true

class TeamMailer < ApplicationMailer
  include ActionView::Helpers::SanitizeHelper

  layout "layouts/email"

  def invite(team_invitation)
    # Delayed jobs must not use stale invitation or seller state from a replica.
    team_invitation = ApplicationRecord.connected_to(role: :writing) do
      TeamInvitation.includes(:seller).find_by(id: team_invitation.id)
    end
    return unless team_invitation&.seller&.account_active?
    return if team_invitation.deleted? || team_invitation.accepted? || team_invitation.expired?
    return unless team_invitation.single_mailbox_email?

    @team_invitation = team_invitation
    @subject = "Gumroad team invitation"

    mail(
      from: NOREPLY_EMAIL_WITH_NAME,
      to: @team_invitation.email,
      reply_to: NOREPLY_EMAIL,
      subject: @subject
    )
  end

  def invitation_accepted(team_membership)
    @team_membership = team_membership
    @user = team_membership.user
    @seller = team_membership.seller
    @user_name = sanitize(@user.display_name(prefer_email_over_default_username: true))
    @subject = "#{@user_name} has accepted your invitation"

    mail(
      from: NOREPLY_EMAIL_WITH_NAME,
      to: @seller.email,
      reply_to: @user.email,
      subject: @subject
    )
  end
end
