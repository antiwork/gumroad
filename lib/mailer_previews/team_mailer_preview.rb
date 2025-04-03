# frozen_string_literal: true

class TeamMailerPreview < ActionMailer::Preview
  def invite
    TeamMailer.invite(TeamInvitation.last)
  end

  def invitation_accepted
    TeamMailer.invitation_accepted(TeamMembership.last)
  end
end
