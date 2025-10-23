# frozen_string_literal: true

# Upload the stamped PDF to S3
module PdfStampingService::UploadToS3
  extend self

  def perform!(product_file:, stamped_pdf_path:)
    guid = SecureRandom.hex
    path = "attachments/#{guid}/original/#{File.basename(product_file.s3_url)}"
    Aws::S3::Resource.new.bucket(S3_BUCKET).object(path).upload_file(
      stamped_pdf_path,
      content_type: "application/pdf"
    )

    "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{path}"
  end
end
