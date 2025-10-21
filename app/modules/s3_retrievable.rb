# frozen_string_literal: true

module S3Retrievable
  extend ActiveSupport::Concern

  GUID_LENGTH = 32

  # Use the guid if it can be found, otherwise use self.url
  # Assumes guid is a 32-character alphanumeric sequence preceding "/original/" in the url
  def unique_url_identifier
    identifier = s3_url.split("/original/").first
    if identifier && identifier != s3_url
      potential_guid = identifier.last(GUID_LENGTH)
      identifier = potential_guid unless /[^A-Za-z0-9]/.match?(potential_guid)
    end
    identifier
  end

  def download_original(encoding: "ascii-8bit")
    raise ArgumentError, "`##{__method__}` requires a block" unless block_given?

    extname = File.extname(s3_url)
    basename = Digest::MD5.hexdigest(File.basename(s3_url, extname))
    tempfile = Tempfile.new([basename, extname], encoding:)
    self.s3_object.download_file(tempfile.path)
    tempfile.rewind
    yield tempfile
  rescue Aws::S3::Errors::NotFound => e
    raise e.exception("Key = #{s3_key} -- #{self.class.name}.id = #{id}")
  ensure
    tempfile&.close!
  end

  class_methods do
    def has_s3_fields(column)
      scope :s3, -> { where("#{column} LIKE ?", "#{S3_BASE_URL}%") }
      scope :with_s3_key, ->(key) { where("#{column} = ?", "#{S3_BASE_URL}#{key}") }

      # Public: Returns the s3 key for the object by which the file can be retrieved from s3.
      define_method(:s3_key) do
        return unless s3?

        s3_url.split("/")[4..-1].join("/")
      end

      define_method(:s3?) do
        return false if s3_url.blank?

        s3_url.starts_with?(S3_BASE_URL)
      end

      define_method(:s3_object) do
        return unless s3?

        Aws::S3::Resource.new.bucket(S3_BUCKET).object(s3_key)
      end

      define_method(:s3_filename) do
        return unless s3?

        splitted = send(column).split("/")
        user_external_id = user.try(:external_id)
        starting_index = 7
        max_split_count = 8
        if user_external_id && send(column) =~ %r{\A#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/\w+/#{user_external_id}/}
          starting_index = 8
          max_split_count = 9
        end
        splitted.count > max_split_count ? splitted[starting_index..-1].join("/") : splitted.last # to handle file names that have / in them.
      end

      define_method(:s3_url) do
        send(column)
      end

      # sample.pdf -> .pdf
      define_method(:s3_extension) do
        return unless s3?

        File.extname(s3_url)
      end

      # sample.pdf -> PDF
      define_method(:s3_display_extension) do
        return unless s3?

        extension = s3_extension
        extension.present? ? extension[1..-1].upcase : ""
      end

      # sample.pdf -> sample
      define_method(:s3_display_name) do
        return unless s3?

        if s3_extension.length > 0
          s3_filename[0...-s3_extension.length]
        else
          s3_filename
        end
      end

      define_method(:s3_directory_uri) do
        return unless s3?
        s3_url.split("/")[4, 3].join("/") # i.e: "attachments/aefc7b6c0f6e14c27edc7a0313e4ee77/original"
      end

      define_method(:restore_deleted_s3_object!) do
        return unless s3?
        return if s3_object.exists?

        bucket = Aws::S3::Resource.new(
          region: AWS_DEFAULT_REGION,
          credentials: Aws::Credentials.new(GlobalConfig.get("S3_DELETER_ACCESS_KEY_ID"), GlobalConfig.get("S3_DELETER_SECRET_ACCESS_KEY"))
        ).bucket(S3_BUCKET)

        restored = false
        bucket.object_versions(prefix: s3_key).each do |object_version|
          next unless object_version.key == s3_key
          next unless object_version.data.is_a?(Aws::S3::Types::DeleteMarkerEntry)
          object_version.delete
          restored = true
          break
        end

        restored
      end

      # Some S3 keys have a different Unicode normalization form in the database than in S3 itself.
      # The only way to know for sure is to try to load the object from S3.
      # If it's missing for that key, we'll try finding it in the S3 directory,
      # as it should be the only file here at that time.
      define_method(:confirm_s3_key!) do
        s3_object.load
      rescue Aws::S3::Errors::NotFound
        files = Aws::S3::Client.new.list_objects(bucket: S3_BUCKET, prefix: s3_directory_uri).first.contents
        return if files.size != 1

        new_url = S3_BASE_URL + files[0].key
        update!(url: new_url)
      end
    end
  end
end
