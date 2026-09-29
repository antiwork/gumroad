# frozen_string_literal: true

# `data` must never hold a name, email or address.
class PiracyReportEvent < ApplicationRecord
  ACTOR_TYPES = %w[seller admin_actor system].freeze

  belongs_to :piracy_report

  validates :event, presence: true
  validates :actor_type, inclusion: { in: ACTOR_TYPES }
end
