# frozen_string_literal: true

# Rewrites one person's address on the rows sellers hold about them: audience members, follows and
# imported customers. Shared by both erasure services so a guest buyer and an account holder leave
# these rows in the same state. Each anonymize method returns the number of rows rewritten.
class GdprAudienceRecordsAnonymizer
  def initialize(email:, anonymized_email:)
    @email = email
    @anonymized_email = anonymized_email
    @search_index_jobs = []
  end

  # Held back from the anonymize step so a caller inside a transaction can queue them after it
  # commits: a rolled-back erasure must not leave the index disagreeing with the rows.
  def enqueue_search_index_jobs!
    while (job = @search_index_jobs.first)
      ElasticsearchIndexerWorker.perform_async(*job)
      @search_index_jobs.shift
    end
  end

  # "index" for rewritten members, "delete" for conflicting ones the anonymize removed.
  def pending_search_index_record_ids(operation)
    @search_index_jobs.filter_map { _2["record_id"] if _1 == operation }.uniq
  end

  def anonymize_audience_members!
    conflict_seller_ids = AudienceMember.where(email: @anonymized_email).pluck(:seller_id)
    if conflict_seller_ids.any?
      conflicting_members = AudienceMember.where(email: @email, seller_id: conflict_seller_ids)
      deleted_member_ids = conflicting_members.ids
      conflicting_members.delete_all
      deleted_member_ids.each do |member_id|
        @search_index_jobs << ["delete", { "record_id" => member_id, "class_name" => "AudienceMember" }]
      end
    end

    anonymized_attributes = {
      email: @anonymized_email,
      details: nil,
      customer: false,
      follower: false,
      affiliate: false,
      min_paid_cents: nil,
      max_paid_cents: nil,
      min_created_at: nil,
      max_created_at: nil,
      min_purchase_created_at: nil,
      max_purchase_created_at: nil,
      follower_created_at: nil,
      min_affiliate_created_at: nil,
      max_affiliate_created_at: nil,
    }
    members = AudienceMember.where(email: @email).to_a
    count = AudienceMember.where(id: members.map(&:id)).update_all(anonymized_attributes)
    # The indexer worker re-reads rows from a possibly-lagging replica; passing the
    # document body inline guarantees the pre-erasure PII can never be re-indexed.
    members.each do |member|
      member.assign_attributes(anonymized_attributes)
      @search_index_jobs << ["index", { "record_id" => member.id, "class_name" => "AudienceMember", "body" => member.as_indexed_json }]
    end
    count
  end

  def anonymize_followers!
    conflict_followed_ids = Follower.where(email: @anonymized_email).pluck(:followed_id)
    Follower.where(email: @email, followed_id: conflict_followed_ids).delete_all if conflict_followed_ids.any?
    Follower.where(email: @email).update_all(email: @anonymized_email)
  end

  def anonymize_imported_customers!
    ImportedCustomer.where(email: @email).update_all(email: @anonymized_email)
  end
end
