# frozen_string_literal: true

module Streamable
  extend ActiveSupport::Concern

  included do
    has_many :transcoded_videos, as: :streamable
  end

  def attempt_to_transcode?(allowed_when_processing: false)
    # Don't transcode if another transcoding job is already pending for this particular video.
    return false if !allowed_when_processing && transcoded_videos.alive.processing.exists?(original_video_key: s3_key)

    # Don't transcode if the video is already transcoded.
    return false if transcoded_videos.alive.completed.exists?(original_video_key: s3_key)

    true
  end

  def transcodable?
    streamable? && height.present? && width.present?
  end

  def transcoding_in_progress?
    streamable? && transcoded_videos.alive.processing.exists?(original_video_key: s3_key)
  end

  def transcoding_failed
  end

  def streamable?
    true
  end

  # This method returns a string representing the secured m3u8 HLS playlist
  # content for this product file.
  #
  # This method can return nil if there are no transcoded videos for the
  # product file.
  def hls_playlist
    last_hls_transcoded_video = transcoded_videos.alive.is_hls.completed.last
    return nil if last_hls_transcoded_video.nil?

    playlist_key = last_hls_transcoded_video.transcoded_video_key
    hls_key_prefix = "#{File.dirname(playlist_key)}/" # Extract path without the filename

    playlist_s3_object = Aws::S3::Resource.new.bucket(S3_BUCKET).object(playlist_key)
    playlist = playlist_s3_object.get.body.read
    playlist_content_with_signed_urls = ""

    playlist.split("\n").each do |playlist_line|
      if playlist_line.start_with?("#")
        playlist_content_with_signed_urls += "#{playlist_line}\n"
        next
      end

      resolution_specific_playlist_key = playlist_line
      resolution_specific_playlist_key.prepend(hls_key_prefix)

      # Escape the user-provided portion of the URL, which is the original file
      # name. Note that the ProductFile could have been renamed by now. That's
      # why we get the original file name from the hls_key_prefix, which comes
      # from the TranscodedVideo object that was created when the video was
      # originally transcoded.
      original_file_name = if hls_key_prefix.include?("/original/")
        hls_key_prefix[%r{/original/(.*?)/hls}m, 1]
      else
        hls_key_prefix[%r{attachments/.*/(.*?)/hls}m, 1]
      end
      resolution_specific_playlist_key.gsub!(
        original_file_name,
        CGI.escape(original_file_name)
      )

      signed_resolution_specific_playlist_url = signed_cloudfront_url(
        "#{HLS_DISTRIBUTION_URL}#{resolution_specific_playlist_key}",
        is_video: true
      )
      playlist_content_with_signed_urls += "#{signed_resolution_specific_playlist_url}\n"
    end

    playlist_content_with_signed_urls
  end
end
