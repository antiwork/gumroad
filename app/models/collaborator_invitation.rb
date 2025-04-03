# frozen_string_literal: true

class CollaboratorInvitation < ApplicationRecord
  include ExternalId

  belongs_to :collaborator

  def accept!
    destroy!
    AffiliateMailer.collaborator_invitation_accepted(collaborator_id).deliver_later
  end

  def decline!
    collaborator.mark_deleted!
    AffiliateMailer.collaborator_invitation_declined(collaborator_id).deliver_later
  end
end
