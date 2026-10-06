# frozen_string_literal: true

class PiracyReportPolicy < ApplicationPolicy
  def new?
    create?
  end

  # The flag is the whole gate: a seller without it has no surface to report from.
  def create?
    Feature.active?(:piracy_reports, seller)
  end

  def show?
    sign?
  end

  # The notice carries the seller's legal name, so only the seller on the report can read or sign it.
  def sign?
    when_record_available { record.seller_id == seller&.id }
  end
end
