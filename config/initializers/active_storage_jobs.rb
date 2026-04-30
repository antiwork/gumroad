# frozen_string_literal: true

# ActiveStorage::AnalyzeJob runs asynchronously after a blob is attached.
# If the blob is purged from S3 before the job executes (e.g., the parent
# record is deleted), S3 returns NoSuchKey. Retrying is pointless because the
# object will never reappear, so we discard the job silently.
Rails.application.config.after_initialize do
  ActiveStorage::AnalyzeJob.discard_on(Aws::S3::Errors::NoSuchKey)
end
