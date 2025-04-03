# frozen_string_literal: true

require "spec_helper"

describe RemoveDeletedFilesFromS3Job do
  before do
    allow_any_instance_of(described_class).to receive(:delete_s3_objects!)
  end

  it "removes recently deleted files from S3" do
    product_file = create(:product_file, deleted_at: 26.hours.ago)
    product_file_archive = create(:product_files_archive, deleted_at: 26.hours.ago)
    subtitle_file = create(:subtitle_file, deleted_at: 26.hours.ago)

    described_class.new.perform
    expect(product_file.reload.deleted_from_cdn_at).to be_present
    expect(product_file_archive.reload.deleted_from_cdn_at).to be_present
    expect(subtitle_file.reload.deleted_from_cdn_at).to be_present
  end

  it "does not remove older deleted files from S3" do
    product_file = create(:product_file, deleted_at: 1.year.ago)
    product_file_archive = create(:product_files_archive, deleted_at: 1.year.ago)
    subtitle_file = create(:subtitle_file, deleted_at: 1.year.ago)

    described_class.new.perform
    expect(product_file.reload.deleted_from_cdn_at).to be_nil
    expect(product_file_archive.reload.deleted_from_cdn_at).to be_nil
    expect(subtitle_file.reload.deleted_from_cdn_at).to be_nil
  end

  it "does not attempt to delete files already marked as removed from S3" do
    create(:product_file, deleted_at: 26.hours.ago, deleted_from_cdn_at: 26.hours.ago)
    create(:product_files_archive, deleted_at: 26.hours.ago, deleted_from_cdn_at: 26.hours.ago)
    create(:subtitle_file, deleted_at: 26.hours.ago, deleted_from_cdn_at: 26.hours.ago)

    expect_any_instance_of(described_class).not_to receive(:delete_s3_object!)
    described_class.new.perform
  end

  it "does not remove files with existing alive duplicate files from S3" do
    product_file_1 = create(:product_file, deleted_at: 26.hours.ago)
    product_file_2 = create(:product_file, url: product_file_1.url)
    subtitle_file_1 = create(:subtitle_file, deleted_at: 26.hours.ago)
    subtitle_file_2 = create(:subtitle_file, url: subtitle_file_1.url)
    # product file archives can't have duplicate urls

    described_class.new.perform
    expect(product_file_1.reload.deleted_from_cdn_at).to be_nil
    expect(product_file_2.reload.deleted_from_cdn_at).to be_nil
    expect(subtitle_file_1.reload.deleted_from_cdn_at).to be_nil
    expect(subtitle_file_2.reload.deleted_from_cdn_at).to be_nil
  end

  it "notifies Bugsnag and continues when there's an error removing a file" do
    instance = described_class.new
    product_file_1 = create(:product_file, deleted_at: 26.hours.ago)
    product_file_2 = create(:product_file, deleted_at: 26.hours.ago)

    allow(instance).to receive(:remove_record_files).and_call_original
    allow(instance).to receive(:remove_record_files).with(satisfy { _1.id == product_file_1.id }).and_raise(RuntimeError.new)
    expect(Bugsnag).to receive(:notify).with(an_instance_of(RuntimeError))

    instance.perform
    expect(product_file_1.deleted_from_cdn_at).to be_nil
    expect(product_file_2.reload.deleted_from_cdn_at).to be_present
  end
end
