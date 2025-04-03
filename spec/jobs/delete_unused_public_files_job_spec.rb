# frozen_string_literal: true

require "spec_helper"

describe DeleteUnusedPublicFilesJob do
  it "deletes public files scheduled for deletion" do
    public_file = create(:public_file, :with_audio, scheduled_for_deletion_at: 1.day.ago)

    described_class.new.perform

    public_file.reload
    expect(public_file).to be_deleted
    expect(public_file.file).not_to be_attached
  end

  it "does not delete public files not scheduled for deletion" do
    public_file = create(:public_file, :with_audio)
    expect(public_file.file).to be_attached

    described_class.new.perform

    public_file.reload
    expect(public_file).not_to be_deleted
    expect(public_file.file).to be_attached
  end

  it "does not delete public files scheduled for future deletion" do
    public_file = create(:public_file, :with_audio, scheduled_for_deletion_at: 1.day.from_now)
    expect(public_file.file).to be_attached

    described_class.new.perform

    public_file.reload
    expect(public_file).not_to be_deleted
    expect(public_file.file).to be_attached
  end

  it "only deletes the blob if no other attachments reference it" do
    public_file1 = create(:public_file, :with_audio, scheduled_for_deletion_at: 1.day.ago)
    public_file2 = create(:public_file)
    public_file2.file.attach(public_file1.file.blob)
    expect(public_file1.file).to be_attached
    expect(public_file2.file).to be_attached

    described_class.new.perform

    public_file1.reload
    public_file2.reload
    expect(public_file1).to be_deleted
    expect(public_file1.file).to be_attached
    expect(public_file2.file).to be_attached
  end

  it "handles transaction rollback if deletion fails" do
    public_file = create(:public_file, :with_audio, scheduled_for_deletion_at: 1.day.ago)
    allow_any_instance_of(ActiveStorage::Attached::One).to receive(:purge_later).and_raise(ActiveStorage::FileNotFoundError)

    expect do
      described_class.new.perform
    end.to raise_error(ActiveStorage::FileNotFoundError)

    public_file.reload
    expect(public_file).to_not be_deleted
    expect(public_file.file).to be_attached
  end
end
