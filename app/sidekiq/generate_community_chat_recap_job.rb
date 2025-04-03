# frozen_string_literal: true

class GenerateCommunityChatRecapJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 1, lock: :until_executed

  def perform(community_chat_recap_id)
    community_chat_recap = CommunityChatRecap.find(community_chat_recap_id)
    CommunityChatRecapGeneratorService.new(community_chat_recap:).process
    community_chat_recap.community_chat_recap_run.check_if_finished!
  end

  FailureHandler = ->(job, e) do
    if job["class"] == "GenerateCommunityChatRecapJob"
      recap_id = job["args"]&.first
      return if recap_id.blank?

      recap = CommunityChatRecap.find_by(id: recap_id)
      return if recap.blank?

      recap.update!(status: "failed", error_message: e.message)
      recap.community_chat_recap_run.check_if_finished!
    end
  end

  sidekiq_retries_exhausted(&FailureHandler)
end
