# frozen_string_literal: true

class SentPostEmail < ApplicationRecord
  LOOKUP_BATCH_SIZE = 1_000

  belongs_to :post, class_name: "Installment", optional: true
  before_validation :downcase_email
  validates_presence_of :email

  def downcase_email
    return if email.blank?
    self.email = email.downcase
  end

  # No index leads with email, so rows are reached through the posts of every seller the address is
  # linked to: each row is written for that seller's buyer, follower, affiliate or audience member.
  # `rewritten_to` is where an erasure moves those links, so their sellers are still found afterwards.
  def self.ids_for_email(email, rewritten_to:)
    addresses = [email, rewritten_to]
    seller_ids = [
      Purchase.where(email: addresses).distinct.pluck(:seller_id),
      Follower.where(email: addresses).distinct.pluck(:followed_id),
      AudienceMember.where(email: addresses).distinct.pluck(:seller_id),
      Affiliate.where(affiliate_user_id: User.where(email: addresses).ids).distinct.pluck(:seller_id),
    ].flatten.compact.uniq
    post_ids = seller_ids.each_slice(LOOKUP_BATCH_SIZE).flat_map { Installment.where(seller_id: _1).ids }
    post_ids.each_slice(LOOKUP_BATCH_SIZE).flat_map { where(post_id: _1, email:).ids }
  end

  # A locking read, so a retry inside a transaction sees rows committed after its snapshot. A plain read
  # would keep missing them and insert_all_emails would recurse until the stack runs out.
  def self.missing_emails(post:, emails:)
    emails - where(post:, email: emails).lock("FOR SHARE").pluck(:email)
  end

  # `source` is the record the address was read from. The claim is written only while that row still
  # holds the address, under a share lock: a GDPR erasure that rewrites the row either commits first and
  # is seen here, or waits for this commit, and its cleanup then removes or rewrites the claim. The lock
  # is released before the block runs.
  def self.ensure_uniqueness(post:, email:, source:)
    return if email.blank?
    claimed = ApplicationRecord.connected_to(role: :writing) do
      transaction do
        source.class.where(id: source.id).lock("FOR SHARE").pick(:email) == email && create!(post:, email:)
      end
    end
  rescue ActiveRecord::RecordNotUnique
    # noop
  else
    # Ids only: the address is what may have just been erased.
    Rails.logger.info("SentPostEmail: skipped post #{post.id} for #{source.class.name} #{source.id}, whose address changed") unless claimed
    yield if claimed
  end

  # Returns array of emails that were just inserted.
  # Assumes all emails are present?.
  def self.insert_all_emails(post:, emails:)
    return [] if emails.empty?
    insert_all!(emails.map { { post_id: post.id, email: _1 } })
    emails
  rescue ActiveRecord::RecordNotUnique
    insert_all_emails(post:, emails: missing_emails(post:, emails:))
  end
end
