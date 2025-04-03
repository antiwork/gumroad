# frozen_string_literal: true

class Call < ApplicationRecord
  include ExternalId

  belongs_to :purchase

  delegate :link, to: :purchase

  attr_readonly :start_time, :end_time
  normalizes :start_time, :end_time, with: -> { _1.change(sec: 0) }

  validates_presence_of :start_time, :end_time

  validate :start_time_is_before_end_time
  validate :purchase_product_is_call
  validate :selected_time_is_available, on: :create, unless: :selected_time_availability_already_validated?

  scope :occupies_availability, -> { joins(:purchase).merge(Purchase.counts_towards_inventory.not_fully_refunded) }
  scope :upcoming, -> { where(end_time: Time.current..) }
  scope :ordered_chronologically, -> { order(start_time: :asc, end_time: :asc) }
  scope :starts_on_date, ->(start_time, timezone) { where(start_time: start_time.in_time_zone(timezone).all_day) }
  scope :overlaps_with, ->(start_time, end_time) { where("start_time < ? AND end_time > ?", end_time, start_time) }

  after_create_commit :schedule_reminder_emails
  after_create_commit :send_google_calendar_invites

  def formatted_time_range
    start_time = self.start_time.in_time_zone(link.user.timezone)
    end_time = self.end_time.in_time_zone(link.user.timezone)
    "#{start_time.strftime("%I:%M %p")} - #{end_time.strftime("%I:%M %p")} #{start_time.strftime("%Z")}"
  end

  def formatted_date_range
    start_time = self.start_time.in_time_zone(link.user.timezone)
    end_time = self.end_time.in_time_zone(link.user.timezone)
    formatted_start_date = start_time.strftime("%A, %B #{start_time.day.ordinalize}, %Y")
    if start_time.to_date == end_time.to_date
      formatted_start_date
    else
      formatted_end_date = end_time.strftime("%A, %B #{end_time.day.ordinalize}, %Y")
      "#{formatted_start_date} - #{formatted_end_date}"
    end
  end

  def eligible_for_reminder?
    return false if purchase.is_gift_sender_purchase?
    return true if purchase.in_progress?

    purchase.successful_and_not_reversed?(include_gift: true)
  end

  private
    def start_time_is_before_end_time
      return if start_time.blank? || end_time.blank?
      if start_time >= end_time
        errors.add(:base, "Start time must be before end time.")
      end
    end

    def purchase_product_is_call
      if link.native_type != Link::NATIVE_TYPE_CALL
        errors.add(:base, "Purchased product must be a call")
      end
    end

    def selected_time_is_available
      return if start_time.blank? || end_time.blank?
      return if link.call_limitation_info&.allows?(start_time) && start_time_and_end_time_available?
      errors.add(:base, "Selected time is no longer available")
    end

    def start_time_and_end_time_available?
      link.sold_calls.occupies_availability.overlaps_with(start_time, end_time).empty? &&
        link.call_availabilities.containing(start_time, end_time).exists?
    end

    def selected_time_availability_already_validated?
      purchase.is_gift_receiver_purchase?
    end

    def schedule_reminder_emails
      return unless eligible_for_reminder?

      reminder_time = start_time - 1.day
      return if reminder_time.past?

      ContactingCreatorMailer.upcoming_call_reminder(id).deliver_later(wait_until: reminder_time)
      CustomerMailer.upcoming_call_reminder(id).deliver_later(wait_until: reminder_time)
    end

    def send_google_calendar_invites
      if link.has_integration?(Integration.type_for(Integration::GOOGLE_CALENDAR))
        GoogleCalendarInviteJob.perform_async(id)
      end
    end
end
