# frozen_string_literal: true

class Api::V2::FilesController < Api::V2::BaseController
  before_action { doorkeeper_authorize! :edit_products }

  PRESIGNED_URL_EXPIRY_SECONDS = 900
  PART_SIZE = 100.megabytes
  MAX_FILE_SIZE_GB = 20 # matching the web uploader limit
  MAX_FILE_SIZE = MAX_FILE_SIZE_GB.gigabytes

  def presign
    filename = ActiveStorage::Filename.new(params[:filename].to_s).sanitized
    return error_400("filename is required") if filename.blank?

    file_size = params[:file_size].to_s.to_i
    return error_400("file_size is required") if file_size <= 0
    return error_400("file_size exceeds the #{MAX_FILE_SIZE_GB} GB maximum") if file_size > MAX_FILE_SIZE

    guid = SecureRandom.hex
    key = "#{s3_key_prefix}#{guid}/original/#{filename}"

    s3 = Aws::S3::Client.new
    upload_id = s3.create_multipart_upload(bucket: S3_BUCKET, key:).upload_id

    presigner = Aws::S3::Presigner.new
    part_count = file_size.fdiv(PART_SIZE).ceil
    parts = (1..part_count).map do |part_number|
      {
        part_number:,
        presigned_url: presigner.presigned_url(
          :upload_part,
          bucket: S3_BUCKET,
          key:,
          upload_id:,
          part_number:,
          expires_in: PRESIGNED_URL_EXPIRY_SECONDS,
        )
      }
    end

    render json: { success: true, upload_id:, key:, file_url: s3_file_url(key), parts: }
  rescue Aws::S3::Errors::ServiceError => e
    error_400(e.message)
  end

  def complete
    upload_id = params[:upload_id].to_s
    key = params[:key].to_s

    return error_400("upload_id is required") if upload_id.blank?
    return error_400("key is required") if key.blank?
    return error_400("parts is required") if params[:parts].blank?

    return error_400("invalid key") unless key.start_with?(s3_key_prefix)

    parts = Array(params[:parts]).map { |p| { part_number: p[:part_number].to_i, etag: p[:etag].to_s } }

    Aws::S3::Client.new.complete_multipart_upload(
      bucket: S3_BUCKET,
      key:,
      upload_id:,
      multipart_upload: { parts: }
    )

    render json: { success: true, file_url: s3_file_url(key) }
  rescue Aws::S3::Errors::ServiceError => e
    error_400(e.message)
  end

  def abort
    upload_id = params[:upload_id].to_s
    key = params[:key].to_s

    return error_400("upload_id is required") if upload_id.blank?
    return error_400("key is required") if key.blank?
    return error_400("invalid key") unless key.start_with?(s3_key_prefix)

    Aws::S3::Client.new.abort_multipart_upload(bucket: S3_BUCKET, key:, upload_id:)

    render json: { success: true, status: "accepted" }
  rescue Aws::S3::Errors::NoSuchUpload
    render json: { success: true, status: "already_gone" }
  rescue Aws::S3::Errors::ServiceError => e
    error_400(e.message)
  end

  private
    def s3_key_prefix
      "attachments/#{current_resource_owner.external_id}/"
    end

    def s3_file_url(key)
      "#{S3_BASE_URL}#{key}"
    end
end
