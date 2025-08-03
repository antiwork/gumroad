# frozen_string_literal: true

class AffiliateInvitation < ApplicationRecord
  include ExternalId

  belongs_to :affiliate, foreign_key: :affiliate_id

  def accept!
    destroy!
    AffiliateMailer.affiliate_invitation_accepted(affiliate_id).deliver_later
  end

  def decline!
    affiliate.mark_deleted!
    AffiliateMailer.affiliate_invitation_declined(affiliate_id).deliver_later
  end
end
