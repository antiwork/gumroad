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

  def last_successful_charge_at
    charges.successful.last.succeeded_at.strftime("%B #{charges.successful.last.succeeded_at.day.ordinalize}, %Y")
  end

  def cancelled_or_failed?
    cancelled_at.present? || failed_at.present?
  end

  def renewal_at
    charges.successful.last.succeeded_at + recurrence_duration
  end

  def formatted_price
    "#{MoneyFormatter.format(price_cents, :usd, no_cents_if_whole: true, symbol: true)} #{recurrence_long_indicator}"
  end

  private
    def create_service_charge_event(service_charge)
      original_service_charge_event = Event.find_by(service_charge_id: charges.successful.first.id)
      return nil if original_service_charge_event.nil?

      new_service_charge_event = original_service_charge_event.dup
      new_service_charge_event.assign_attributes(
        service_charge_id: service_charge.id,
        purchase_state: service_charge.state,
        price_cents: service_charge.charge_cents,
        card_visual: service_charge.card_visual,
        card_type: service_charge.card_type,
        billing_zip: service_charge.card_zip_code
      )

      new_service_charge_event.save!
    end
end
