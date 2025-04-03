# frozen_string_literal: true

class CommunityChatRecapRun < ApplicationRecord
  has_many :community_chat_recaps, dependent: :destroy

  validates :recap_frequency, :from_date, :to_date, presence: true
  validates :recap_frequency, uniqueness: { scope: [:from_date, :to_date] }

  enum :recap_frequency, { daily: "daily", weekly: "weekly" }, prefix: true, validate: true

  scope :running, -> { where(finished_at: nil) }
  scope :finished, -> { where.not(finished_at: nil) }
  scope :between, ->(from_date, to_date) { where("from_date >= ? AND to_date <= ?", from_date, to_date) }

  after_save_commit :trigger_weekly_recap_run
  after_save_commit :send_recap_notifications

  def finished?
    finished_at.present?
  end

  def check_if_finished!
    return if finished?
    recap_statuses = community_chat_recaps.pluck(:status)
    return if recap_statuses.include?("pending")
    return if (recaps_count - recap_statuses.select { |status| status.in?(%w[finished failed]) }.size) > 0

    update!(finished_at: Time.current)
  end

  private
    def trigger_weekly_recap_run
      return unless recap_frequency_daily?
      return unless finished?
      return unless Date::DAYNAMES[from_date.wday] == "Saturday"

      TriggerCommunityChatRecapRunJob.perform_async("weekly", (from_date.to_date - 6.days).to_date.to_s)
    end

    def send_recap_notifications
      return unless finished?
      return if notified_at.present?

      SendCommunityChatRecapNotificationsJob.perform_async(id)

      update!(notified_at: Time.current)
    end
end
