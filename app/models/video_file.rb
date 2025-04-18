# frozen_string_literal: true

class VideoFile < ApplicationRecord
  include WithFileProperties
  include Deletable
  include S3Retrievable
  include CdnDeletable, CdnUrlHelper
  include SignedUrlHelper
  include FlagShihTzu

  include VideoFile::HasThumbnail

  has_s3_fields :url

  belongs_to :record, polymorphic: true
  belongs_to :user

  has_flags 1 => :is_transcoded_for_hls,
            2 => :analyze_completed,
            :flag_query_mode => :bit_operator

  validates :url, presence: true
  validate :url_is_s3

  after_create_commit :schedule_file_analysis

  def smil_xml
    smil_xml = ::Builder::XmlMarkup.new

    smil_xml.smil do |smil|
      smil.body do |body|
        body.switch do |switch|
          switch.video(src: signed_cloudfront_url(s3_key, is_video: true))
        end
      end
    end
  end

  def signed_download_url
    signed_download_url_for_s3_key_and_filename(s3_key, s3_filename, is_video: true)
  end

  private
    def schedule_file_analysis
      AnalyzeFileWorker.perform_async(id, self.class.name)
    end

    def url_is_s3
      errors.add(:url, "must be an S3 URL") unless s3?
    end
end
