# frozen_string_literal: true

# Leaves an internal note on a seller's account when content moderation blocks
# a publish. This runs as a background job (rather than inline in the
# moderation check) because the check executes inside the failing record's
# save transaction: the blocked save raises, the transaction rolls back, and a
# synchronously created comment would be erased along with it. Pushing to
# Sidekiq escapes the transaction, so the audit trail survives the rollback.
class ContentModerationAdminCommentJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  def perform(user_id, content)
    user = User.find_by(id: user_id)
    return if user.nil?

    # A seller retrying a blocked publish re-triggers the moderation check, so
    # identical notes within a short window are duplicates, not new events.
    return if user.comments
                  .with_type_note
                  .where(author_name: ContentModeration::ModerateRecordService::AUTHOR_NAME, content:)
                  .where("created_at > ?", ContentModeration::ModerateRecordService::ADMIN_COMMENT_DEDUP_WINDOW.ago)
                  .exists?

    user.comments.create!(
      author_name: ContentModeration::ModerateRecordService::AUTHOR_NAME,
      comment_type: Comment::COMMENT_TYPE_NOTE,
      content:,
    )
  end
end
