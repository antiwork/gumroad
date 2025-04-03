# frozen_string_literal: true

class TriggerCommunityChatRecapRunJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  def perform(recap_frequency, from_date = nil)
    raise ArgumentError, "Recap frequency must be daily or weekly" unless recap_frequency.in?(CommunityChatRecapRun.recap_frequencies.values)

    from_date = (from_date.present? ? Date.parse(from_date) : recap_frequency == "daily" ? Date.yesterday : Date.yesterday - 6.days).beginning_of_day
    to_date = (recap_frequency == "daily" ? from_date : from_date + 6.days).end_of_day

    ActiveRecord::Base.transaction do
      recap_run = CommunityChatRecapRun.find_or_initialize_by(recap_frequency:, from_date:, to_date:)
      return if recap_run.persisted?
      community_ids = CommunityChatMessage.alive.where(created_at: from_date..to_date).pluck(:community_id).uniq
      recap_run.recaps_count = community_ids.size
      recap_run.finished_at = DateTime.current if community_ids.size == 0
      recap_run.save!

      community_ids.each do |community_id|
        recap = recap_run.community_chat_recaps.create!(community_id:)
        GenerateCommunityChatRecapJob.perform_async(recap.id)
      end
    end
  end
end
