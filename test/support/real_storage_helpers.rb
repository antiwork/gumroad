# frozen_string_literal: true

# Opt-in real object storage for the Minitest suite.
#
# test_helper.rb points ActiveStorage at a local Disk service by default so the
# vast majority of file-attaching tests stay fast and need no S3. A test that
# genuinely needs real S3 semantics (presigned URLs, S3-specific behavior) wraps
# the relevant section in `with_real_s3 { ... }`, which swaps the default service
# to the S3 service configured in config/storage.yml (`:test`, pointing at the
# MinIO container — see AWS_S3_ENDPOINT in .env.test / the CI `minio` service) for
# the duration of the block and restores the Disk service afterward.
module RealStorageHelpers
  def with_real_s3
    previous_services = ActiveStorage::Blob.services
    previous_service = ActiveStorage::Blob.service

    s3_config = Rails.configuration.active_storage.service_configurations.slice("test")
    ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(s3_config)
    ActiveStorage::Blob.service = ActiveStorage::Blob.services.fetch(:test)

    yield
  ensure
    ActiveStorage::Blob.services = previous_services
    ActiveStorage::Blob.service = previous_service
  end
end

ActiveSupport::TestCase.include(RealStorageHelpers)
