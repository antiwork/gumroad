# frozen_string_literal: true

class Comment < ApplicationRecord
  include ExternalId
  include Deletable
  include JsonData

  COMMENT_TYPE_USER_SUBMITTED = "user_submitted"
  COMMENT_TYPE_PAYOUT_NOTE = "payout_note"
  COMMENT_TYPE_COMPLIANT = "compliant"
  COMMENT_TYPE_ON_PROBATION = "on"
  COMMENT_TYPE_FLAGGED = "flagged"
  COMMENT_TYPE_FLAG_NOTE = "flag_note"
  COMMENT_TYPE_SUSPENDED = "suspended"
  COMMENT_TYPE_SUSPENSION_NOTE = "suspension_note"
  COMMENT_TYPE_BALANCE_FORFEITED = "balance_forfeited"
  COMMENT_TYPE_COUNTRY_CHANGED = "country_changed"
  COMMENT_TYPE_PAYOUTS_PAUSED = "payouts_paused"
  COMMENT_TYPE_PAYOUTS_RESUMED = "payouts_resumed"
  RISK_STATE_COMMENT_TYPES = [COMMENT_TYPE_COMPLIANT, COMMENT_TYPE_ON_PROBATION, COMMENT_TYPE_FLAGGED, COMMENT_TYPE_SUSPENDED]
  MAX_ALLOWED_DEPTH = 4 # Depth of a root comment starts with 0.

  attr_json_data_accessor :was_alive_before_marking_subtree_deleted

  has_ancestry cache_depth: true
  has_paper_trail

  belongs_to :commentable, polymorphic: true, optional: true
  belongs_to :author, class_name: "User", optional: true
  belongs_to :purchase, optional: true

  validates_presence_of :commentable_id, :commentable_type, :comment_type, :content
  validates :content, length: { maximum: 10_000 }
  validates :depth, numericality: { only_integer: true, less_than_or_equal_to: MAX_ALLOWED_DEPTH }, on: :create
  validate :commentable_object_exists, on: :create
  validate :content_cannot_contain_adult_keywords, if: :content_changed?
  validate :author_name_or_author_id_is_present

  before_save :trim_extra_newlines, if: :content_changed?
  after_commit :notify_seller_of_new_comment, on: :create

  scope :with_type_payout_note, -> { where(comment_type: COMMENT_TYPE_PAYOUT_NOTE) }
  scope :with_type_on_probation, -> { where(comment_type: COMMENT_TYPE_ON_PROBATION) }
  scope :with_type_payouts_paused, -> { where(comment_type: COMMENT_TYPE_PAYOUTS_PAUSED) }
  scope :with_type_payouts_resumed, -> { where(comment_type: COMMENT_TYPE_PAYOUTS_RESUMED) }

  def mark_subtree_deleted!
    transaction do
      subtree.alive.each do |comment|
        comment.was_alive_before_marking_subtree_deleted = true if comment.id != id
        comment.mark_deleted!
      end
    end
  end

  def mark_subtree_undeleted!
    transaction do
      subtree.deleted.each do |comment|
        comment.json_data.delete("was_alive_before_marking_subtree_deleted")
        comment.mark_undeleted!
      end
    end
  end

  private
    def commentable_object_exists
      obj_exists = case commentable_type
                   when "Installment" then Installment.exists?(commentable_id)
                   when "Link" then Link.exists?(commentable_id)
                   when "Purchase" then Purchase.exists?(commentable_id)
                   when "User" then User.exists?(commentable_id)
                   else false
      end
      errors.add :base, "object to annotate does not exist" unless obj_exists
    end

    def author_name_or_author_id_is_present
      errors.add :base, "author_name or author_id must be present" if author_name.blank? && author_id.blank?
    end

    def content_cannot_contain_adult_keywords
      return if author&.is_team_member?
      return if !author && author_name == "iffy"

      errors.add(:base, "Adult keywords are not allowed") if AdultKeywordDetector.adult?(content)
    end

    def trim_extra_newlines
      self.content = content.strip.gsub(/(\R){3,}/, '\1\1')
    end

    def notify_seller_of_new_comment
      return unless user_submitted?
      return unless root?
      return if authored_by_seller?
      return if commentable.seller.disable_comments_email?

      CommentMailer.notify_seller_of_new_comment(id).deliver_later
    end

    def user_submitted?
      comment_type == COMMENT_TYPE_USER_SUBMITTED
    end

    def authored_by_seller?
      commentable.respond_to?(:seller_id) && commentable.seller_id == author_id
    end
end
