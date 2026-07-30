# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillVideoPosterImages do
  before { GenerateVideoPosterWorker.jobs.clear }

  it "enqueues generation for a live video cover with no persisted poster" do
    asset_preview = create(:asset_preview_mov)
    GenerateVideoPosterWorker.jobs.clear

    expect(described_class.process).to eq(enqueued: 1, skipped: 0)
    expect(GenerateVideoPosterWorker.jobs.map { _1["args"].first }).to eq([asset_preview.id])
  end

  # AssetPreview treats any blob whose content type starts with "video" as a
  # video cover, so the backfill has to match the same set. Enumerating specific
  # formats here would leave covers in the less common ones without a durable
  # poster — exactly the state this backfill exists to clear.
  it "enqueues generation for a video format outside the common few" do
    asset_preview = create(:asset_preview_mov)
    asset_preview.file.blob.update!(content_type: "video/x-matroska")
    GenerateVideoPosterWorker.jobs.clear

    expect(described_class.process).to eq(enqueued: 1, skipped: 0)
    expect(GenerateVideoPosterWorker.jobs.map { _1["args"].first }).to eq([asset_preview.id])
  end

  it "skips a cover whose poster is already persisted, so re-running costs nothing" do
    asset_preview = create(:asset_preview_mov)
    asset_preview.file.blob.preview_image.attach(
      io: File.open(Rails.root.join("spec", "support", "fixtures", "test-small.jpg")),
      filename: "poster.jpg",
      content_type: "image/jpeg"
    )
    GenerateVideoPosterWorker.jobs.clear

    expect(described_class.process).to eq(enqueued: 0, skipped: 1)
    expect(GenerateVideoPosterWorker.jobs).to be_empty
  end

  # The batch is selected by id, then read again to eager-load the blobs. That
  # second read has to stay inside the eligibility scope: ReplicaLagWatcher.watch
  # runs between the two, so a cover deleted in that window would otherwise still
  # get a generation job.
  it "does not enqueue a cover that stopped being eligible after its batch was selected" do
    asset_preview = create(:asset_preview_mov)
    GenerateVideoPosterWorker.jobs.clear

    allow(ReplicaLagWatcher).to receive(:watch) { asset_preview.mark_deleted! }

    expect(described_class.process).to eq(enqueued: 0, skipped: 0)
    expect(GenerateVideoPosterWorker.jobs).to be_empty
  end

  it "does not enqueue a cover whose file was detached after its batch was selected" do
    asset_preview = create(:asset_preview_mov)
    GenerateVideoPosterWorker.jobs.clear

    allow(ReplicaLagWatcher).to receive(:watch) { asset_preview.file.purge }

    expect(described_class.process).to eq(enqueued: 0, skipped: 0)
    expect(GenerateVideoPosterWorker.jobs).to be_empty
  end

  it "does not enqueue a cover retyped to a non-video after its batch was selected" do
    asset_preview = create(:asset_preview_mov)
    GenerateVideoPosterWorker.jobs.clear

    allow(ReplicaLagWatcher).to receive(:watch) do
      asset_preview.file.blob.update!(content_type: "image/jpeg")
    end

    expect(described_class.process).to eq(enqueued: 0, skipped: 0)
    expect(GenerateVideoPosterWorker.jobs).to be_empty
  end

  it "leaves image covers and deleted video covers alone" do
    create(:asset_preview_jpg)
    create(:asset_preview_mov).mark_deleted!
    GenerateVideoPosterWorker.jobs.clear

    expect(described_class.process).to eq(enqueued: 0, skipped: 0)
    expect(GenerateVideoPosterWorker.jobs).to be_empty
  end
end
