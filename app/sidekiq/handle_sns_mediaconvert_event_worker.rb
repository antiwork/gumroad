# frozen_string_literal: true

class HandleSnsMediaconvertEventWorker
  include Sidekiq::Job
  include TranscodeEventHandler
  sidekiq_options retry: 5, queue: :default

  ERROR_STATUS = "ERROR"

  def perform(notification)
    return unless notification["Type"] == "Notification"

    message = JSON.parse(notification["Message"])["detail"]
    job_id = message["jobId"]

    transcoded_video = TranscodedVideo.find_by(job_id:)
    return if transcoded_video.nil?

    if message["status"] == ERROR_STATUS
      # Transcode in ETS
      ets_transcoder = TranscodeVideoForStreamingWorker::ETS
      TranscodeVideoForStreamingWorker.perform_in(
        5.seconds,
        transcoded_video.streamable_id,
        transcoded_video.streamable_type,
        ets_transcoder
      )
      transcoded_video.destroy!
    else
      handle_transcoding_job_notification(job_id, transcoded_state(message), transcoded_video_key(message))
    end
  end

  private
    def transcoded_video_key(message)
      message["outputGroupDetails"]
        .first["playlistFilePaths"]
        .first
        .delete_prefix("s3://#{S3_BUCKET}/") # Strip protocol and bucket name from the file path
    end

    def transcoded_state(message)
      message["status"] == "COMPLETE" ? "COMPLETED" : message["status"]
    end
end
