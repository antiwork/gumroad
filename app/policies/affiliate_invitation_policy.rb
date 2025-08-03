# frozen_string_literal: true

class AffiliateInvitationPolicy < ApplicationPolicy
  def accept?
    user == record.affiliate.affiliate_user
  end

  def decline?
    accept?
  end
end
