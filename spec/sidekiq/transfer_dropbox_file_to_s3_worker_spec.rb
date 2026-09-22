# frozen_string_literal: true

require "spec_helper"

describe TransferDropboxFileToS3Worker do
  it "reads the import and transfers it inside the primary database scope" do
    dropbox_file = create(:dropbox_file, expires_at: 1.hour.from_now)
    primary_scope = false
    expect(ApplicationRecord).to receive(:connected_to).with(role: :writing).and_wrap_original do |original, **options, &block|
      original.call(**options) do
        primary_scope = true
        block.call
      ensure
        primary_scope = false
      end
    end
    expect(DropboxFile).to receive(:find).with(dropbox_file.id).and_wrap_original do |original, id|
      expect(primary_scope).to eq(true)
      original.call(id)
    end
    expect_any_instance_of(DropboxFile).to receive(:multipart_transfer_to_s3) do
      expect(primary_scope).to eq(true)
    end

    described_class.new.perform(dropbox_file.id)
  end

  it "does not transfer a cancelled import" do
    dropbox_file = create(:dropbox_file, expires_at: 1.hour.from_now)
    dropbox_file.mark_cancelled!
    expect_any_instance_of(DropboxFile).not_to receive(:multipart_transfer_to_s3)

    described_class.new.perform(dropbox_file.id)

    expect(dropbox_file.reload).to be_cancelled
  end
end
