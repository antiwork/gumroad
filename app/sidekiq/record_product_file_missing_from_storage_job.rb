# frozen_string_literal: true

# Records, on the row itself, that a ProductFile's upload never put anything in
# storage — so nobody has to ask storage about that row again.
#
# Attaching a file to a product creates the row before the browser has finished
# uploading the object (see `WithProductFiles#save_files!`). If that upload never
# finishes, the row stays alive pointing at a key that was never written:
# `analyze` gives up on the missing object, `analyze_completed` is never set, and
# nothing else revisits the row. It then permanently reads as "only storage can
# say" (`ProductFile#stored_file_presence_known_from_row` returns nil), which
# means every caller that needs to know whether the listing delivers anything
# pays a storage lookup to re-learn the same answer — most importantly the
# spam-flag deliverable check, which can only afford a bounded number of lookups
# per save and can be pushed off a genuinely stored file by a pile of these dead
# rows (gumroad#6320, gumroad-private#1370).
#
# `deleted_from_cdn_at` is the existing "there is no object in storage behind
# this row" marker, and it is exactly the claim we've just proved, so that is
# what gets set: from then on the row answers for itself, for free, forever. The
# row is left alive, so the seller's file list is unchanged — a dead row is not
# something we should silently remove from someone's product.
#
# The check is redone here rather than trusted from the caller: the caller's
# lookup happened during a save, and by the time this job runs the upload may
# have completed, the file may have been analyzed, or the row may have been
# deleted.
class RecordProductFileMissingFromStorageJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  # How long after a row is created we still allow for its upload to be in
  # flight. A multipart upload of a large file over a slow connection can take a
  # long while, and marking a row that is still uploading would tell every later
  # caller the file is missing when it is about to be there. A day is far longer
  # than any real upload and still retires the row long before it can matter.
  UPLOAD_GRACE_PERIOD = 1.day

  def perform(product_file_id)
    file = ProductFile.alive.find_by(id: product_file_id)
    return if file.nil?
    return unless self.class.eligible?(file)
    return if file.s3_object.exists?

    file.mark_deleted_from_cdn
  end

  # Whether this row is one whose absence from storage is worth recording: an S3
  # file we have never successfully analyzed, not already marked, and old enough
  # that its upload cannot still be in progress.
  def self.eligible?(file)
    file.s3? &&
      !file.analyze_completed? &&
      !file.deleted_from_cdn? &&
      file.created_at.present? &&
      file.created_at <= UPLOAD_GRACE_PERIOD.ago
  end
end
