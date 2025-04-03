# frozen_string_literal: true

class CallAvailability < ApplicationRecord
  include ExternalId

  belongs_to :call, class_name: "Link"

  normalizes :start_time, :end_time, with: -> { _1.change(sec: 0) }

  validates_presence_of :call, :start_time, :end_time

  validate :start_time_is_before_end_time

  scope :upcoming, -> { where(end_time: Time.current..) }
  scope :ordered_chronologically, -> { order(start_time: :asc, end_time: :asc) }
  scope :containing, ->(start_time, end_time) { where("start_time <= ? AND ? <= end_time", start_time, end_time) }

  private
    def start_time_is_before_end_time
      if start_time >= end_time
        errors.add(:base, "Start time must be before end time.")
      end
    end
end
