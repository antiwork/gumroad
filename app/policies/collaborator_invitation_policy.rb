# frozen_string_literal: true

class CollaboratorInvitationPolicy < ApplicationPolicy
  def accept?
    user.role_admin_for?(seller) &&
      record.collaborator.affiliate_user == seller
  end

  def decline?
    accept?
  end
end
