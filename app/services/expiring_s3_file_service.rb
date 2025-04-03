# frozen_string_literal: true

class ExpiringS3FileService
  DEFAULT_FILE_EXPIRY = 7.days

  def initialize(file:,
                 filename: nil,
                 path: nil,
                 prefix: "File",
                 extension: nil,
                 expiry: DEFAULT_FILE_EXPIRY,
                 bucket: S3_BUCKET)
    raise ArgumentError.new("Either filename or extension is required") unless filename || extension
    @file = file
    timestamp = Time.current.strftime("%s")
    filename ||= "#{prefix}_#{timestamp}_#{SecureRandom.hex}.#{extension}"
    @key = path.present? ? File.join(path, filename) : filename
    @expiry = expiry.to_i
    @bucket = bucket
  end

  def perform
    s3_obj = Aws::S3::Resource.new.bucket(@bucket).object(@key)
    # Uses upload_file which takes care of large files automatically for us:
    # https://docs.aws.amazon.com/sdkforruby/api/Aws/S3/Object.html#upload_file-instance_method
    s3_obj.upload_file(@file, content_type: MIME::Types.type_for(@key).first.to_s)
    s3_obj.presigned_url(:get, expires_in: @expiry, response_content_disposition: "attachment")
  end
end
