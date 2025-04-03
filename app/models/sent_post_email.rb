# frozen_string_literal: true

class SentPostEmail < ApplicationRecord
  belongs_to :post, class_name: "Installment", optional: true
  before_validation :downcase_email
  validates_presence_of :email

  def downcase_email
    return if email.blank?
    self.email = email.downcase
  end

  def self.missing_emails(post:, emails:)
    emails - where(post:, email: emails).pluck(:email)
  end

  def self.ensure_uniqueness(post:, email:)
    return if email.blank?
    create!(post:, email:)
  rescue ActiveRecord::RecordNotUnique
    # noop
  else
    yield
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
