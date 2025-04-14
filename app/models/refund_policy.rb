# frozen_string_literal: true

class RefundPolicy < ApplicationRecord
  include ExternalId

  has_paper_trail

  ALLOWED_REFUND_PERIODS_IN_DAYS = {
    0 => "No refunds allowed",
    7 => "7-day money back guarantee",
    14 => "14-day money back guarantee",
    30 => "30-day money back guarantee",
    183 => "6-month money back guarantee",
  }.freeze
  DEFAULT_REFUND_PERIOD_IN_DAYS = 30

  attribute :max_refund_period_in_days, :integer, default: RefundPolicy::DEFAULT_REFUND_PERIOD_IN_DAYS

  belongs_to :seller, class_name: "User"

  stripped_fields :title, :fine_print, transform: -> { ActionController::Base.helpers.strip_tags(_1) }

  validates_presence_of :seller
  validates :fine_print, length: { maximum: 3_000 }

  validates :max_refund_period_in_days, inclusion: { in: ALLOWED_REFUND_PERIODS_IN_DAYS.keys }

  def title
    ALLOWED_REFUND_PERIODS_IN_DAYS[max_refund_period_in_days]
  end

  def as_json(*)
    {
      fine_print:,
      id: external_id,
      title:,
    }
  end
end
