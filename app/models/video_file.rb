# frozen_string_literal: true

class VideoFile < ApplicationRecord
  include WithFileProperties
  include Deletable
  include S3Retrievable
  include CdnDeletable, CdnUrlHelper
  include FlagShihTzu

  has_s3_fields :url

  belongs_to :record, polymorphic: true

  has_flags 1 => :is_transcoded_for_hls,
            2 => :analyze_completed,
            :flag_query_mode => :bit_operator

  validates :url, presence: true
  validate :url_is_s3

  after_create_commit :schedule_file_analysis

  private
    def schedule_file_analysis
      AnalyzeFileWorker.perform_async(id, self.class.name)
    end

    def url_is_s3
      errors.add(:url, "must be an S3 URL") unless s3?
    end
end
