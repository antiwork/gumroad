# frozen_string_literal: true

class RemoveDeletedFilesFromS3Job
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  # There is no need to try to remove S3 objects from records that were marked as deleted years ago, and whose removal failed:
  # those will need to be dealt with manually.
  # Because this job is called every day, it ensures we'll try to remove objects at least once, but not much more than that.
  MAX_DELETION_AGE_IN_DAYS = 3

  # If there's a need to run this job over a larger period of time than just the last 3 days of deleted files,
  # you can enqueue it like this:
  # RemoveDeletedFilesFromS3Job.perform_async(60) # => all records marked as deleted up to 60 days ago will be considered

  def perform(max_deletion_age_in_days = MAX_DELETION_AGE_IN_DAYS)
    [
      ProductFile,
      ProductFilesArchive,
      SubtitleFile,
      StampedPdf,
      TranscodedVideo,
    ].each do |model|
      remove_records_files(model.where(deleted_at: max_deletion_age_in_days.days.ago .. 24.hours.ago))
    end
  end

  private
    def remove_records_files(scoped_model)
      scoped_model.cdn_deletable.find_each do |file|
        next if file.has_alive_duplicate_files?
        remove_record_files(file)
      rescue => e
        Bugsnag.notify(e) { _1.add_tab(:file, model: file.class.name, id: file.id, url: file.try(:url)) }
      end
    end

    def remove_record_files(file)
      s3_keys = if file.is_a?(TranscodedVideo)
        gather_transcoded_video_keys(file)
      else
        [file.s3_key]
      end.compact_blank

      delete_s3_objects!(s3_keys) unless s3_keys.empty?
      file.mark_deleted_from_cdn
    end

    def s3
      @_s3 ||= begin
        credentials = Aws::Credentials.new(GlobalConfig.get("S3_DELETER_ACCESS_KEY_ID"), GlobalConfig.get("S3_DELETER_SECRET_ACCESS_KEY"))
        Aws::S3::Resource.new(region: AWS_DEFAULT_REGION, credentials:)
      end
    end

    def bucket
      @_bucket ||= s3.bucket(S3_BUCKET)
    end

    def delete_s3_objects!(s3_keys)
      s3_keys.each_slice(1_000) do |keys_slice|
        s3_objects = keys_slice.map { { key: _1 } }
        s3.client.delete_objects(bucket: S3_BUCKET, delete: { objects: s3_objects, quiet: true })
      end
    end

    def gather_transcoded_video_keys(file)
      key = file.transcoded_video_key
      return [] unless /\/hls\/(index\.m3u8)?$/.match?(key) # sanity check: only deal with keys ending with /hls/ or /hls/index.m3u8
      hls_dir = key.delete_suffix("index.m3u8")
      keys = bucket.objects(prefix: hls_dir).map(&:key)
      keys.delete_if { _1.delete_prefix(hls_dir).include?("/") } # sanity check: ignore any sub-directories in /hls/
    end
end
