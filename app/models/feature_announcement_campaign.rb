# frozen_string_literal: true

# The copy and audience of one FeatureAnnouncementMailer campaign. Jobs carry only the key, and
# approval freezes the copy: the handoff gate refuses a message whose copy no longer matches
# the digest taken at approval.
class FeatureAnnouncementCampaign < ApplicationRecord
  STATES = %w[draft approved sending sent cancelled].freeze
  DELIVERABLE_STATES = %w[sending sent].freeze
  # Each audience names a FeatureAnnouncementMailer.<audience>_audience? predicate.
  AUDIENCES = %w[creators piracy_reports].freeze
  CONTENT_ATTRIBUTES = %w[subject body reply_to].freeze

  class InvalidTransition < StandardError; end

  belongs_to :approved_by, class_name: "User", optional: true

  validates :key, presence: true, uniqueness: true, length: { maximum: 64 }, format: { with: /\A[a-z0-9_]+\z/ }
  validates :subject, :body, :reply_to, presence: true
  # Replies reach a Gumroad inbox only.
  validates :reply_to, email_format: true, format: { with: /@gumroad\.com\z/ }
  validates :audience, inclusion: { in: AUDIENCES }
  validates :state, inclusion: { in: STATES }
  validate :links_use_https
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

  # The caller passes the digest of the copy it showed for approval, so a draft edited after
  # that preview is not approved.
  def approve!(by:, digest:)
    with_lock do
      raise InvalidTransition, "only a draft can be approved" unless state == "draft"
      raise InvalidTransition, "the copy changed since the preview" unless digest == current_digest

      update!(state: "approved", content_digest: digest, approved_by: by, approved_at: Time.current)
    end
  end

  # A campaign already sending can be sent again, which recovers from an enqueue that failed after
  # the state changed. The gate's claims stop a second email to anyone.
  def start_sending!
    with_lock do
      raise InvalidTransition, "only an approved campaign can be sent" unless %w[approved sending].include?(state)

      update!(state: "sending")
    end
    SendFeatureAnnouncementCampaignJob.perform_async(id)
  end

  # A sent campaign can still have emails in the queue, so it can be cancelled too.
  def cancel!
    with_lock do
      raise InvalidTransition, "the campaign is already cancelled" if state == "cancelled"

      update!(state: "cancelled")
    end
  end

  private
    def links_use_https
      hrefs = Nokogiri::HTML.fragment(body.to_s).css("a").map { _1["href"].to_s }
      errors.add(:body, "links must use https") unless hrefs.all? { _1.start_with?("https://") }
    end

    def content_frozen_after_draft
      return if state_was == "draft"

      CONTENT_ATTRIBUTES.each { errors.add(_1, "can't change after approval") if will_save_change_to_attribute?(_1) }
    end
end
