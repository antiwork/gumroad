# frozen_string_literal: true

class AffiliateInvitationPolicy < ApplicationPolicy
  def accept?
    user == record.affiliate.affiliate_user
  end

  def decline?
    accept?
  end

  def cancel?
    user == record.affiliate.seller
  end
end
