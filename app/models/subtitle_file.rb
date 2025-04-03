# frozen_string_literal: true

class SubtitleFile < ApplicationRecord
  include S3Retrievable, ExternalId, JsonData, Deletable, CdnDeletable

  VALID_FILE_TYPE_REGEX = /\A.+\.(srt|sub|sbv|vtt)\z/

  has_paper_trail

  belongs_to :product_file, optional: true

  validates_presence_of :product_file, :url

  validate :ensure_valid_file_type, unless: :deleted?

  has_s3_fields :url

  after_commit :schedule_calculate_size, on: :create

  def user
    product_file.try(:user)
  end

  def mark_deleted
    self.deleted_at = Time.current
  end

  def size_displayable
    ActionController::Base.helpers.number_to_human_size(size)
  end

  def calculate_size
    self.size = s3_object.content_length
    save!
  end

  def schedule_calculate_size
    SubtitleFileSizeWorker.perform_in(5.seconds, id)
  end

  def has_alive_duplicate_files?
    SubtitleFile.alive.where(url:).exists?
  end

  private
    def ensure_valid_file_type
      return if url.match?(VALID_FILE_TYPE_REGEX)
      errors.add(:base, "Subtitle type not supported. Please upload only subtitles with extension .srt, .sub, .sbv, or .vtt.")
    end
end
