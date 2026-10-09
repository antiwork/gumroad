# frozen_string_literal: true

class PiracyReportPolicy < ApplicationPolicy
  def index?
    user.role_admin_for?(seller)
  end

  # The Products tab shows only when there is a list this user can open.
  def tab?
    index? && PiracyReport.filed_by?(seller)
  end

  def new?
    create?
  end

  def create?
    Feature.active?(:piracy_reports, seller) && user.role_admin_for?(seller)
  end

  def show?
    sign?
  end

  # The notice carries the seller's legal name, so only the owner or an admin can read or sign it.
  def sign?
    user.role_admin_for?(seller) && when_record_available { record.seller_id == seller&.id }
  end

  def cancel?
    sign?
  end
end
