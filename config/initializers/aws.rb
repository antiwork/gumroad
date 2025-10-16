# frozen_string_literal: true

# aws credentials for the web app are stored in the secrets
AWS_ACCESS_KEY = GlobalConfig.get("AWS_ACCESS_KEY_ID")
AWS_SECRET_KEY = GlobalConfig.get("AWS_SECRET_ACCESS_KEY")
AWS_S3_ENDPOINT = GlobalConfig.get("AWS_S3_ENDPOINT", "https://s3.amazonaws.com")
AWS_DEFAULT_REGION = GlobalConfig.get("AWS_DEFAULT_REGION", "us-east-1")

aws_config = {
  region: AWS_DEFAULT_REGION,
  credentials: Aws::Credentials.new(AWS_ACCESS_KEY, AWS_SECRET_KEY)
}

# Support for MinIO in development and test environments
if Rails.env.development? || Rails.env.test?
  aws_config[:endpoint] = AWS_S3_ENDPOINT if AWS_S3_ENDPOINT.present?
  Aws.config[:s3] = { force_path_style: true }
end

Aws.config.update(aws_config)

INVOICES_S3_BUCKET = GlobalConfig.get("INVOICES_S3_BUCKET", "gumroad-invoices")
S3_CREDENTIALS = { access_key_id: AWS_ACCESS_KEY, secret_access_key: AWS_SECRET_KEY, s3_region: AWS_DEFAULT_REGION }.freeze
CLOUDFRONT_KEYPAIR_ID = GlobalConfig.get("CLOUDFRONT_KEYPAIR_ID")
CLOUDFRONT_PRIVATE_KEY = GlobalConfig.get("CLOUDFRONT_PRIVATE_KEY").then do |key|
  OpenSSL::PKey::RSA.new(key) if key.present?
end

SECURITY_LOG_BUCKETS = { production: "gumroad-logs-security", staging: "gumroad-logs-security-staging" }.freeze

KINDLE_EMAIL_REGEX = /\A(?=.{3,255}$)(                                         # between 3 and 255 characters
                     ([^@\s()\[\],.<>;:\\"]+(\.[^@\s()\[\],.<>;:\\"]+)*))      # cannot start with or have consecutive dots
                     @kindle\.com\z/xi

S3_BUCKET = {
  development: "gumroad_dev",
  staging: "gumroad_dev",
  test: "gumroad-specs",
  production: "gumroad"
}[Rails.env.to_sym]

S3_BASE_URL = GlobalConfig.get("S3_BASE_URL_TEMPLATE", "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/")


PUBLIC_STORAGE_S3_BUCKET = {
  development: "gumroad-dev-public-storage",
  staging: "gumroad-dev-public-storage",
  test: "gumroad-specs",
  production: "gumroad-public-storage"
}[Rails.env.to_sym]

if Rails.env.production?
  # Streaming
  HLS_DISTRIBUTION_URL = GlobalConfig.get("HLS_DISTRIBUTION_URL_PROD", "https://d1bdh6c3ceakz5.cloudfront.net/")
  HLS_PIPELINE_ID = GlobalConfig.get("HLS_PIPELINE_ID_PROD", "1390492023700-rfbrn0")

  # File Download
  FILE_DOWNLOAD_DISTRIBUTION_URL = GlobalConfig.get("FILE_DOWNLOAD_DISTRIBUTION_URL_PROD", "https://files.gumroad.com/")
  CLOUDFRONT_DOWNLOAD_DISTRIBUTION_URL = GlobalConfig.get("CLOUDFRONT_DOWNLOAD_DISTRIBUTION_URL_PROD", "https://d2dw6lv4z9w0e2.cloudfront.net/")
else
  # Streaming
  HLS_DISTRIBUTION_URL = GlobalConfig.get("HLS_DISTRIBUTION_URL_DEV", "https://d1jmbc8d0c0hid.cloudfront.net/")
  HLS_PIPELINE_ID = GlobalConfig.get("HLS_PIPELINE_ID_DEV", "1390090734092-rg9pq5")

  # File Download
  FILE_DOWNLOAD_DISTRIBUTION_URL = GlobalConfig.get("FILE_DOWNLOAD_DISTRIBUTION_URL_DEV", "https://staging-files.gumroad.com/")
  CLOUDFRONT_DOWNLOAD_DISTRIBUTION_URL = GlobalConfig.get("CLOUDFRONT_DOWNLOAD_DISTRIBUTION_URL_DEV", "https://d3t5lixau6dhwk.cloudfront.net/")
end

HLS_PRESETS = {
  "hls_1080p" => "1591945283540-xff1kg",
  "hls_720p" => "1591945673240-8jq7vk",
  "hls_480p" => "1591945700851-ma7v1l"
}

AWS_ACCOUNT_ID = GlobalConfig.get("AWS_ACCOUNT_ID")
mediaconvert_queue_name = Rails.env.production? ? "production" : "staging"
MEDIACONVERT_QUEUE = GlobalConfig.get("MEDIACONVERT_QUEUE_TEMPLATE", "arn:aws:mediaconvert:us-east-1:#{AWS_ACCOUNT_ID}:queues/#{mediaconvert_queue_name}")
MEDIACONVERT_ROLE = GlobalConfig.get("MEDIACONVERT_ROLE", "arn:aws:iam::#{AWS_ACCOUNT_ID}:role/service-role/MediaConvert_Default_Role")
MEDIACONVERT_ENDPOINT = GlobalConfig.get("MEDIACONVERT_ENDPOINT", "https://lxlxpswfb.mediaconvert.us-east-1.amazonaws.com")
