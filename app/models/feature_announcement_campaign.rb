# frozen_string_literal: true

# The copy and audience of one FeatureAnnouncementMailer campaign. Jobs carry only the key, and
# approval freezes the copy: the handoff gate refuses a message whose copy no longer matches
# the digest taken at approval.
class FeatureAnnouncementCampaign < ApplicationRecord
  STATES = %w[draft approved sending sent cancelled].freeze
  DELIVERABLE_STATES = %w[sending sent].freeze
  # Each audience names a FeatureAnnouncementMailer.<audience>_audience? predicate.
  AUDIENCES = %w[piracy_reports].freeze
  CONTENT_ATTRIBUTES = %w[subject body reply_to].freeze

  belongs_to :approved_by, class_name: "User", optional: true

  validates :key, presence: true, uniqueness: true, length: { maximum: 64 }, format: { with: /\A[a-z0-9_]+\z/ }
  validates :subject, :body, :reply_to, presence: true
  # Replies reach a Gumroad inbox only.
  validates :reply_to, email_format: true, format: { with: /@gumroad\.com\z/ }
  validates :audience, inclusion: { in: AUDIENCES }
  validates :state, inclusion: { in: STATES }
  validate :content_frozen_after_draft, on: :update

  def self.digest_for(subject, body, reply_to)
    Digest::SHA256.hexdigest([subject, body, reply_to].to_json)
  end

  def deliverable?
    DELIVERABLE_STATES.include?(state) && content_digest.present? && content_digest == current_digest
  end

  def current_digest
    self.class.digest_for(subject, body, reply_to)
  end

  private
    def content_frozen_after_draft
      return if state_was == "draft"

      CONTENT_ATTRIBUTES.each { errors.add(_1, "can't change after approval") if will_save_change_to_attribute?(_1) }
    end
end
