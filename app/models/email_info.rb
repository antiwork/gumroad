# frozen_string_literal: true

class EmailInfo < ApplicationRecord
  include ExternalId

  # Note: For performance, the state transitions (and validations) are ignored when sending
  # an email in PostSendgridApi.

  belongs_to :purchase, optional: true
  belongs_to :installment, optional: true
  has_one :email_info_charge, dependent: :destroy
  accepts_nested_attributes_for :email_info_charge

  delegate :charge_id, to: :email_info_charge, allow_nil: true

  # EmailInfo state transitions:
  #
  # created  →  sent  →  delivered  →  opened
  #             ↓ ↑
  #           bounced
  #
  state_machine :state, initial: :created do
    before_transition any => :sent, do: ->(email_info) { email_info.sent_at = Time.current }
    before_transition any => :sent, :do => :clear_event_time_fields
    before_transition any => :delivered, do: ->(email_info, transition) { email_info.delivered_at = transition.args.first || Time.current }
    before_transition any => :opened, do: ->(email_info, transition) { email_info.opened_at = transition.args.first || Time.current }
    after_transition any => :bounced, :do => :unsubscribe_buyer

    event :mark_bounced do
      transition any => :bounced
    end

    event :mark_sent do
      transition any => :sent
    end

    event :mark_delivered do
      transition any => :delivered
    end

    event :mark_opened do
      transition any => :opened
    end
  end

  def clear_event_time_fields
    self.delivered_at = nil
    self.opened_at = nil
  end

  def most_recent_state_at
    if opened_at.present?
      opened_at
    elsif delivered_at.present?
      delivered_at
    else
      sent_at
    end
  end

  def unsubscribe_buyer
    if charge_id
      email_info_charge.charge.order.unsubscribe_buyer
    else
      purchase.orderable.unsubscribe_buyer
    end
  end
end
