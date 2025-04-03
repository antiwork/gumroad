# frozen_string_literal: true

class HandleSnsTranscoderEventWorker
  include Sidekiq::Job
  include TranscodeEventHandler
  sidekiq_options retry: 5, queue: :default

  def perform(params)
    if params["Type"] == "Notification"
      message = JSON.parse(params["Message"])

      job_id = message["jobId"]
      state = message["state"]

      handle_transcoding_job_notification(job_id, state)
    end
  end
end
