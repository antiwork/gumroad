# frozen_string_literal: true

# ActiveStorage::AnalyzeJob runs asynchronously after a blob is attached.
# If the blob is purged from S3 before the job executes (e.g., the parent
# record is deleted), S3 returns NoSuchKey. Retrying is pointless because the
# object will never reappear, so we discard the job silently.
Rails.application.config.after_initialize do
  ActiveStorage::AnalyzeJob.discard_on(Aws::S3::Errors::NoSuchKey)

  # ActiveStorage::PreviewImageJob generates preview images for uploaded files.
  # When the underlying file is corrupt or uses a codec our ffmpeg build can't
  # decode, the previewer raises ActiveStorage::PreviewError. The failure is
  # deterministic for that file — retrying can never succeed — so we discard
  # the job with a warning instead of letting it retry and report each attempt.
  ActiveStorage::PreviewImageJob.discard_on(ActiveStorage::PreviewError) do |job, error|
    Rails.logger.warn("[ActiveStorage] Discarding PreviewImageJob (unpreviewable file): #{error.message.lines.first&.strip}")
  end
end
