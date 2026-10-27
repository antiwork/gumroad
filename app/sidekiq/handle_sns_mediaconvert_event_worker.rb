# frozen_string_literal: true

class HandleSnsMediaconvertEventWorker
  include Sidekiq::Job
  include TranscodeEventHandler
  sidekiq_options retry: 5, queue: :default

  def perform(notification)
    return unless notification["Type"] == "Notification"

    message = JSON.parse(notification["Message"])["detail"]
    handle_transcoding_job_notification(message["jobId"], transcoded_state(message), transcoded_video_key(message))
  end

  private
    # An ERROR event carries no output details.
    def transcoded_video_key(message)
      message.dig("outputGroupDetails", 0, "playlistFilePaths", 0)
        &.delete_prefix("s3://#{S3_BUCKET}/") # Strip protocol and bucket name from the file path
    end

    def transcoded_state(message)
      message["status"] == "COMPLETE" ? "COMPLETED" : message["status"]
    end
end
