# frozen_string_literal: true

class ForceFinishLongRunningCommunityChatRecapRunsJob
  include Sidekiq::Job

  MAX_RUNNING_TIME_IN_HOURS = 6

  def perform
    CommunityChatRecapRun.running.where("created_at < ?", MAX_RUNNING_TIME_IN_HOURS.hours.ago).find_each do |recap_run|
      recap_run.community_chat_recaps.status_pending.find_each do |recap|
        recap.update!(status: "failed", error_message: "Recap run cancelled because it took longer than #{MAX_RUNNING_TIME_IN_HOURS} hours to complete")
      end
      recap_run.update!(finished_at: DateTime.current)
    end
  end
end
