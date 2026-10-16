# frozen_string_literal: true

class SentPostEmail < ApplicationRecord
  belongs_to :post, class_name: "Installment", optional: true
  before_validation :downcase_email
  validates_presence_of :email

  def downcase_email
    return if email.blank?
    self.email = email.downcase
  end

  # No index leads with email, so this skip-scans (post_id, email). Its work grows with the number of
  # distinct post_ids, not with this address's rows, and the session max_execution_time bounds it.
  # Without the hint the optimizer reads the whole index instead.
  def self.ids_for_email(email)
    optimizer_hints("SKIP_SCAN(sent_post_emails index_sent_post_emails_on_post_id_and_email)")
      .where(email:)
      .pluck(:id)
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
