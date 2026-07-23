# frozen_string_literal: true

require "test_helper"

# Proves the CI `minio` service + the `with_real_s3` opt-in are wired end-to-end:
# a blob written through the real S3 service lands in MinIO and reads back. The
# rest of the suite keeps using the fast Disk service; this is the one place that
# exercises real object storage, so the opt-in path can't silently rot.
class MinioAvailabilityTest < ActiveSupport::TestCase
  test "with_real_s3 stores and reads a blob through the MinIO-backed S3 service" do
    with_real_s3 do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("hello minio"),
        filename: "minio-smoke.txt",
        content_type: "text/plain"
      )

      assert_instance_of ActiveStorage::Service::S3Service, blob.service
      assert blob.service.exist?(blob.key), "expected the blob to exist in MinIO"
      assert_equal "hello minio", blob.download
    ensure
      blob&.purge
    end
  end

  test "the default ActiveStorage service stays the fast local Disk service" do
    assert_instance_of ActiveStorage::Service::DiskService, ActiveStorage::Blob.service
  end
end
