# frozen_string_literal: true

require "spec_helper"

describe S3MultipartStream do
  let(:s3_client) { Aws::S3::Client.new }
  let(:s3_object) { Aws::S3::Resource.new.bucket(S3_BUCKET).object("specs/multipart-stream-#{SecureRandom.hex}.bin") }

  after { s3_client.delete_object(bucket: S3_BUCKET, key: s3_object.key) }

  def open_uploads
    s3_client.list_multipart_uploads(bucket: S3_BUCKET, prefix: s3_object.key).uploads.select { _1.key == s3_object.key }
  end

  it "stores the written bytes as one object once completed" do
    bytes = Random.new(1).bytes(11.megabytes)
    stream = described_class.new(s3_object, part_size: 5.megabytes, concurrency: 2, content_type: "application/zip")

    (0...bytes.bytesize).step(1.megabyte) { stream.write(bytes.byteslice(_1, 1.megabyte)) }
    stream.complete!(expected_size: bytes.bytesize)

    expect(stream.parts_uploaded).to eq(3)
    expect(stream.max_parts_in_flight).to be <= 2
    expect(s3_object.get.body.read.b).to eq(bytes)
    expect(open_uploads).to be_empty
  end

  it "surfaces a failed part and leaves nothing behind once aborted" do
    stream = described_class.new(s3_object, part_size: 5.megabytes, concurrency: 2)
    allow(s3_object.client).to receive(:upload_part).and_wrap_original do |original, params|
      raise Aws::S3::Errors::InternalError.new(nil, "part failed") if params[:part_number] == 2

      original.call(params)
    end

    expect do
      4.times { stream.write(Random.new(2).bytes(5.megabytes)) }
      stream.complete!(expected_size: 20.megabytes)
    end.to raise_error(described_class::PartUploadError) { |error| expect(error.cause).to be_a(Aws::S3::Errors::InternalError) }
    stream.abort!

    expect(open_uploads).to be_empty
    expect(s3_object.exists?).to be(false)
  end

  it "refuses to complete an object whose byte count differs from the expected size" do
    stream = described_class.new(s3_object, part_size: 5.megabytes, concurrency: 1)
    stream.write("partial")

    expect { stream.complete!(expected_size: 8) }.to raise_error(described_class::SizeMismatchError, /wrote 7 bytes, expected 8/)
    stream.abort!

    expect(open_uploads).to be_empty
    expect(s3_object.exists?).to be(false)
  end

  it "aborts unfinished uploads for exactly its own key" do
    own = s3_client.create_multipart_upload(bucket: S3_BUCKET, key: s3_object.key).upload_id
    sibling_key = "#{s3_object.key}.other"
    sibling = s3_client.create_multipart_upload(bucket: S3_BUCKET, key: sibling_key).upload_id
    # MinIO lists only the exact key here; S3 treats `prefix` as a prefix and returns the sibling too.
    allow(s3_object.client).to receive(:list_multipart_uploads).and_wrap_original do |original, **params|
      listing = original.call(**params)
      listing.uploads.concat(original.call(bucket: S3_BUCKET, prefix: sibling_key).uploads)
      listing
    end

    expect(described_class.abort_unfinished(s3_object)).to eq(1)

    expect(open_uploads).to be_empty
    sibling_uploads = s3_client.list_multipart_uploads(bucket: S3_BUCKET, prefix: sibling_key).uploads.map(&:upload_id)
    expect(sibling_uploads).to eq([sibling])
    expect(sibling_uploads).not_to include(own)
  ensure
    s3_client.abort_multipart_upload(bucket: S3_BUCKET, key: sibling_key, upload_id: sibling) if sibling
  end

  it "rejects a part size below the S3 minimum" do
    expect { described_class.new(s3_object, part_size: 1.megabyte, concurrency: 1) }.to raise_error(ArgumentError)
  end
end
