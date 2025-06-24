# frozen_string_literal: true

class RecurringService < ApplicationRecord
  include ExternalId
  include JsonData
  include DiscountCode
  include RecurringService::Recurrence
  include RecurringService::Tiers

  belongs_to :user, optional: true
  has_many :charges, class_name: "ServiceCharge"
  has_one :latest_charge, -> { order(id: :desc) }, class_name: "ServiceCharge"

  enum recurrence: %i[monthly yearly]

  validates_presence_of :user, :price_cents
  validates_associated :user

  def humanized_renewal_at
    renewal_at.strftime("%B #{renewal_at.day.ordinalize}, %Y")
  end

  def cancelled_or_failed?
    cancelled_at.present? || failed_at.present?
  end

  def renewal_at
    charges.successful.last.succeeded_at + recurrence_duration
  end
end
