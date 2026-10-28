# frozen_string_literal: true

require "spec_helper"

describe ProductBuildUnpackJob do
  let(:product) { create(:product) }
  let(:build) { create(:product_build, product:, number: 1) }
  let(:s3) { Aws::S3::Client.new }

  before do
    s3.list_objects_v2(bucket: S3_BUCKET, prefix: "builds/#{product.id}/1/").contents.each do |object|
      s3.delete_object(bucket: S3_BUCKET, key: object.key)
    end
  end

  def upload_zip(entries)
    buffer = Zip::OutputStream.write_buffer do |zip|
      entries.each do |path, content|
        zip.put_next_entry(path)
        zip.write(content)
      end
    end
    s3.put_object(bucket: S3_BUCKET, key: build.storage_key, body: buffer.string)
  end

  it "unpacks the build's zip into its site prefix" do
    upload_zip("index.html" => "<html></html>")

    described_class.new.perform(build.id)

    expect(s3.get_object(bucket: S3_BUCKET, key: "#{build.site_prefix}/index.html").body.read).to eq("<html></html>")
    expect(build.reload.site_ready?).to be true
  end

  it "records a zip it cannot unpack instead of retrying it" do
    upload_zip("game/index.html" => "<html></html>", "readme.md" => "x")

    expect { described_class.new.perform(build.id) }.not_to raise_error

    expect(build.reload.site_unpack_error).to match(/more than one top-level entry/)
  end

  it "records an archive rubyzip fails to parse instead of retrying it" do
    # A known extra-field ID with a truncated length makes rubyzip raise NoMethodError on open.
    bytes = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("index.html")
      zip.write("x")
    end.string.b
    eocd_at = bytes.rindex("PK\x05\x06".b)
    record = bytes[eocd_at + 16, 4].unpack1("V")
    name_length, extra_length = bytes[record + 28, 4].unpack("vv")
    bytes[record + 30, 2] = [extra_length + 3].pack("v")
    bytes.insert(record + 46 + name_length + extra_length, "UT\x00".b)
    bytes[eocd_at + 3 + 12, 4] = [bytes[eocd_at + 3 + 12, 4].unpack1("V") + 3].pack("V")
    s3.put_object(bucket: S3_BUCKET, key: build.storage_key, body: bytes)

    expect { described_class.new.perform(build.id) }.not_to raise_error

    expect(build.reload.site_unpack_error).to match(/could not be read/)
  end

  it "runs one unpack per build at a time" do
    expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
  end

  it "does nothing when the build is gone" do
    expect { described_class.new.perform(-1) }.not_to raise_error
  end

  it "lets a storage error bubble up so Sidekiq retries it" do
    allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_raise(Aws::S3::Errors::ServiceError.new(nil, "boom"))

    expect { described_class.new.perform(build.id) }.to raise_error(Aws::S3::Errors::ServiceError)
  end
end
