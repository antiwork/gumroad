# frozen_string_literal: true

class PublicFile < ApplicationRecord
  include Deletable

  DELETE_UNUSED_FILES_AFTER_DAYS = 10

  belongs_to :seller, optional: true, class_name: "User"
  belongs_to :resource, polymorphic: true

  has_one_attached :file

  validates :public_id, presence: true, format: { with: /\A[a-z0-9]{16}\z/ }, uniqueness: { case_sensitive: false }
  validates :original_file_name, presence: true
  validates :display_name, presence: true

  before_validation :set_original_file_name
  before_validation :set_default_display_name
  before_validation :set_file_group_and_file_type
  before_validation :set_public_id

  scope :attached, -> { with_attached_file.where(active_storage_attachments: { record_type: "PublicFile" }) }

  def blob
    file&.blob
  end

  # Soft-deletes the record and removes the underlying file from public storage. Because the file
  # lives on Gumroad's PUBLIC bucket, marking the record deleted isn't enough — the URL would keep
  # serving the bytes. The blob is only purged when no other attachment still references it (blobs
  # can be shared between records). Used when a creator deletes a media file, and during account
  # closure / GDPR erasure, where a closed account must not keep hosting files on Gumroad's CDN.
  def mark_deleted_and_purge_file!
    file_blob = blob

    ActiveRecord::Base.transaction do
      mark_deleted!
      purge_blob_later_if_no_live_owner!(file_blob) if file_blob
    end
  end

  def analyzed?
    blob&.analyzed? || false
  end

  def file_size
    blob&.byte_size
  end

  def metadata
    blob&.metadata || {}
  end

  def scheduled_for_deletion?
    scheduled_for_deletion_at.present?
  end

  def schedule_for_deletion!
    update!(scheduled_for_deletion_at: DELETE_UNUSED_FILES_AFTER_DAYS.days.from_now)
  end

  def self.generate_public_id(max_retries: 10)
    retries = 0
    candidate = SecureRandom.alphanumeric.downcase

    while self.exists?(public_id: candidate)
      retries += 1
      raise "Failed to generate unique public_id after #{max_retries} attempts" if retries >= max_retries

      candidate = SecureRandom.alphanumeric.downcase
    end

    candidate
  end

  private
    def purge_blob_later_if_no_live_owner!(file_blob)
      # A blob can be shared by multiple attachments, so only purge when nothing live still points
      # at it. "Live" means: any attachment owned by a non-PublicFile record, or a PublicFile that
      # hasn't been soft-deleted. Both checks are done as queries (rather than loading each
      # attachment's record one by one) so a widely-shared blob doesn't trigger N+1 lookups.
      attachments = ActiveStorage::Attachment.where(blob_id: file_blob.id)
      live_owner_exists =
        attachments.where.not(record_type: "PublicFile").exists? ||
        PublicFile.alive.where(id: attachments.where(record_type: "PublicFile").select(:record_id)).exists?
      file_blob.purge_later unless live_owner_exists
    end

    def set_file_group_and_file_type
      return if original_file_name.blank?

      self.file_type ||= original_file_name.split(".").last
      self.file_group ||= FILE_REGEX.find { |_k, v| v.match?(file_type) }&.first&.split("_")&.last
    end

    def set_original_file_name
      return unless file.attached?
      self.original_file_name ||= file.filename.to_s
    end

    def set_default_display_name
      return if display_name.present?
      return unless file.attached?

      self.display_name = original_file_name.split(".").first.presence || "Untitled"
    end

    def set_public_id
      return if public_id.present?

      self.public_id = self.class.generate_public_id
    end
end
