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
#
# Nothing ever clears the marker, and `stored_file_presence_known_from_row`
# consults it before `analyze_completed?`, so a wrong mark is not self-healing:
# the row would read as empty even if the object later appeared. That is why
# every way a real object can look absent is excluded before writing — the grace
# period below, the Unicode key variants in `perform`, and the storage-error
# path in `ProductFile#stored_file_present?`, which answers "present" on an
# outage and so never reaches the enqueue. If a row is ever marked wrongly, the
# recovery is to null `deleted_from_cdn_at` on it; there is deliberately no
# automatic un-marking, because "the object is back" and "the object was purged"
# are indistinguishable from the row.
class RecordProductFileMissingFromStorageJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  # How long after a row is created we still allow for its upload to be in
  # flight. A multipart upload of a very large file over a slow connection can
  # take a long while, and marking a row that is still uploading would tell every
  # later caller the file is missing when it is about to be there — permanently,
  # since nothing revisits the marker. Three days covers a multi-gigabyte upload
  # on a slow link with room to spare, and still retires the row long before the
  # repeated lookups matter.
  UPLOAD_GRACE_PERIOD = 3.days

  def perform(product_file_id)
    file = ProductFile.alive.find_by(id: product_file_id)
    return if file.nil?
    return unless self.class.eligible?(file)
    # The same accented filename can be encoded two valid ways in Unicode, and S3
    # compares keys byte-for-byte, so a key persisted in one normalization form
    # misses an object stored under the other — `exists?` says missing for a file
    # that is really there and that buyers can still download, because the
    # download path probes the variants (see SignedUrlHelper and
    # S3Retrievable#confirm_s3_key!). Recording "nothing in storage" for such a
    # row would be wrong and, since nothing revisits the marker, wrong forever.
    # For plain-ASCII keys there are no variants and this makes no S3 call.
    return if object_exists_under_another_unicode_form?(file)
    # The key we actually persisted is asked about LAST, so the answer we act on
    # is the newest one we have and the write happens immediately after it. An
    # upload that finishes between the last lookup and the write still gets marked
    # missing — that race is inherent to checking and then writing — but ordering
    # it this way keeps the gap at one request, the same as it was before the
    # variant check existed, instead of leaving up to two more round trips between
    # the canonical answer and the write. (Cost of the order: for an accented
    # filename whose object really is present under the persisted key, we now pay
    # the variant lookups first. That is a handful of rows, and a wasted lookup is
    # the cheap side of this trade — the expensive side is a permanent wrong mark.)
    return if file.s3_object.exists?

    # `mark_deleted_from_cdn` uses `update_column`, which skips paper_trail, and
    # nothing ever clears the marker. So without a log line there is no record of
    # what we marked or why — and if a bad batch ever went out, the only trace
    # would be the timestamp itself. Log enough to reconstruct the decision.
    Rails.logger.info(
      "RecordProductFileMissingFromStorageJob marking product_file=#{file.id} " \
      "as missing from storage (s3_key=#{file.s3_key.inspect}, created_at=#{file.created_at.iso8601})"
    )
    file.mark_deleted_from_cdn
  end

  # Whether this row is one whose absence from storage is worth recording: an S3
  # file not marked analyzed, not already marked, and old enough that its upload
  # cannot still be in progress. (Only video analysis sets `analyze_completed`,
  # so a successfully analyzed PDF or image also passes this gate — the storage
  # lookup in `perform` is what actually decides, and it answers those rows
  # "present".)
  def self.eligible?(file)
    file.s3? &&
      !file.analyze_completed? &&
      !file.deleted_from_cdn? &&
      file.created_at.present? &&
      file.created_at <= UPLOAD_GRACE_PERIOD.ago
  end

  private
    # Whether the object is really in storage under a different Unicode encoding
    # of the same filename. Answers false only when storage positively said there
    # is no such object.
    #
    # A storage fault here (service error, network failure) means we could not
    # tell, and "could not tell" must never become "there is nothing in storage",
    # because that write is permanent. So a fault is treated as "it might be
    # there" and the row is left alone — the same direction in which
    # `ProductFile#stored_file_present?` already resolves an unknown answer. The
    # row stays eligible, so the next save that needs the answer enqueues this
    # job again; the only thing a fault costs is one wasted job.
    def object_exists_under_another_unicode_form?(file)
      S3KeyUnicodeNormalization.existing_variant(file.s3_key).present?
    rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => e
      Rails.logger.info(
        "RecordProductFileMissingFromStorageJob could not check Unicode key variants for " \
        "product_file=#{file.id}, leaving the row alone (#{e.class}: #{e.message})"
      )
      true
    end
end
