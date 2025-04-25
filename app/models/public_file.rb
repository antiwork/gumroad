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
