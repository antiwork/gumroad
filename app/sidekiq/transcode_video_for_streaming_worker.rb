# frozen_string_literal: true

class TranscodeVideoForStreamingWorker
  include Sidekiq::Job
  include Rails.application.routes.url_helpers
  include SignedUrlHelper
  sidekiq_options retry: 13, queue: :default

  MEDIACONVERT = "mediaconvert"
  GRMC = "grmc"
  GRMC_ENDPOINT = "https://production-mediaconverter.gumroad.net/convert"
  GRMC_VIDEO_URL_VALID_FOR = 24.hours
  MEDIACONVERT_OUTPUT_FILENAME = "index"

  def perform(id, klass_name = ProductFile.name, transcoder = GRMC, allowed_when_processing = false)
    ApplicationRecord.connected_to(role: :writing) do
      Rails.logger.info "TranscodeVideoForStreamingWorker: performing for id=#{id}, klass_name=#{klass_name}, transcoder=#{transcoder}"

      if klass_name == Link.name
        Rails.logger.warn "TranscodeVideoForStreamingWorker called for Link ID #{id}. We don't transcode Links anymore."
        return
      end
      streamable = klass_name.constantize.find(id)

      return if streamable.deleted?

      return unless streamable.attempt_to_transcode?(allowed_when_processing:)
      streamable.transcoded_videos.alive.processing.find_each(&:mark_error) if allowed_when_processing

      if streamable.transcodable?
        create_hls_transcode_job(streamable, streamable.s3_key, streamable.height, transcoder)
      else
        Rails.logger.warn "ProductFile with ID #{id} is not transcodable"
        streamable.transcoding_failed
      end
    end
  end

  def create_hls_transcode_job(streamable, original_video_key, input_video_height, transcoder)
    # Every video gets transcoded to 480p regardless of its height. HD Videos get transcoded to at most one more preset depending on their resolution:
    presets = ["hls_480p"]

    if input_video_height >= 1080
      presets << "hls_1080p"
    elsif input_video_height >= 720
      presets << "hls_720p"
    end

    outputs = []
    presets.each do |preset|
      outputs << {
        preset:,
        name_modifier: preset.delete_prefix("hls")
      }
    end

    output_key_prefix = build_output_key_prefix(original_video_key)

    transcoded_video = TranscodedVideo.create!(
      streamable:,
      original_video_key:,
      transcoded_video_key: output_key_prefix,
      is_hls: true
    )

    completed_transcode = TranscodedVideo.alive.completed.where(original_video_key:).last
    if completed_transcode.present?
      # If the video was already successfully transcoded, there is no need to try to actually transcode it again.
      transcoded_video.update!(
        transcoded_video_key: completed_transcode.transcoded_video_key,
        state: "completed"
      )
      # The completion callbacks only run for a job we submit, so nothing else sets the flag on this
      # path, and a file whose rendition was retired earlier keeps sending the web player to the legacy
      # SMIL source while its HLS playlist is back.
      streamable.update!(is_transcoded_for_hls: true) if completed_transcode.is_hls?
      return
    end

    if TranscodedVideo.alive.processing.where(original_video_key:).where.not(id: transcoded_video.id).exists?
      # If the video currently being transcoded by another TranscodedVideo record, there is no need to do anything:
      # when its transcoding is done, all TranscodedVideo records referring to the same S3 key (including this `transcoded_video`)
      # will be marked as completed / error (see TranscodeEventHandler and HandleGrmcCallbackJob).
      return
    end

    if transcoder == GRMC
      begin
        uri = URI.parse(GRMC_ENDPOINT)
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(GlobalConfig.get("GRMC_API_KEY"), "")
        request.content_type = "application/json"
        request.body = {
          # TODO(kyle): Verify that it's safe to use global ID here.
          id: streamable.id.to_s,
          s3_video_uri: "s3://#{S3_BUCKET}/#{original_video_key}",
          video_url: (grmc_source_video_link(original_video_key) if Feature.active?(:grmc_cloudfront_source)),
          s3_hls_dir_uri: "s3://#{S3_BUCKET}/#{output_key_prefix}",
          presets:,
          callback_url: api_internal_grmc_webhook_url(host: API_DOMAIN)
        }.compact.to_json

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request)
        end

        if response.code == "200"
          transcoded_video.update!(
            job_id: JSON.parse(response.body)["job_id"],
            via_grmc: true
          )

          # In case GRMC silently fails to convert video (without calling the callback_url), we want to automatically retry with AWS MediaConvert after a large enough delay
          TranscodeVideoForStreamingWorker.perform_in(24.hours, streamable.id, streamable.class.name, MEDIACONVERT, true)

          return
        elsif response.code == "429"
          Rails.logger.warn("GRMC is busy (#{streamable.class.name} ID #{streamable.id})")
        else
          Rails.logger.warn("Failed request to GRMC (#{streamable.class.name} ID #{streamable.id}): #{response.code} => #{response.body}")
        end
      rescue => e
        Rails.logger.warn("Failed attempt to request GRMC: #{e.class} => #{e.message}")
      end
    end

    begin
      client = Aws::MediaConvert::Client.new(endpoint: MEDIACONVERT_ENDPOINT)
      response = client.create_job(build_mediaconvert_job(original_video_key, output_key_prefix, outputs))
      job = response.job
      transcoded_video.update!(job_id: job.id)
    rescue
      # A raise here leaves this row processing with no job_id, and `attempt_to_transcode?` reads that as
      # an in-flight job, so this worker's own retry returns early and the file never gets a job at all.
      # Erroring the row frees the retry to submit again.
      transcoded_video.mark_error
      raise
    end
  end

  private
    # GRMC runs outside AWS, so reading S3 directly is billed as internet egress; S3 to CloudFront is free.
    # This distribution skips Cloudflare, so source videos stay out of its cache.
    def grmc_source_video_link(original_video_key)
      signed_cloudfront_url(
        "#{CLOUDFRONT_DOWNLOAD_DISTRIBUTION_URL}#{Seahorse::Util.uri_path_escape(original_video_key)}",
        expires_in: GRMC_VIDEO_URL_VALID_FOR
      )
    end

    def build_output_key_prefix(original_video_key)
      extension = File.extname(original_video_key)
      relative_hls_path = "/hls/"

      video_key_without_extension = original_video_key.delete_suffix(extension)
      "#{video_key_without_extension}#{relative_hls_path}"
    end

    def build_mediaconvert_job(original_video_key, output_key_prefix, outputs)
      {
        queue: MEDIACONVERT_QUEUE,
        role: MEDIACONVERT_ROLE,
        settings: {
          output_groups: [
            {
              name: "Apple HLS",
              output_group_settings: {
                type: "HLS_GROUP_SETTINGS",
                hls_group_settings: {
                  segment_length: 10,
                  min_segment_length: 0,
                  destination: "s3://#{S3_BUCKET}/#{output_key_prefix}#{MEDIACONVERT_OUTPUT_FILENAME}",
                  destination_settings: {
                    s3_settings: {
                      access_control: {
                        canned_acl: "PUBLIC_READ"
                      }
                    }
                  }
                }
              },
              outputs:
            }
          ],
          inputs: [
            {
              audio_selectors: {
                "Audio Selector 1": {
                  default_selection: "DEFAULT"
                }
              },
              video_selector: {
                rotate: "AUTO"
              },
              file_input: "s3://#{S3_BUCKET}/#{original_video_key}"
            }
          ]
        },
        acceleration_settings: {
          mode: "DISABLED"
        }
      }
    end
end
