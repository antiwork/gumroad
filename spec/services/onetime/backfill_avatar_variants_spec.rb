# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillAvatarVariants do
  let(:job_queue) { instance_double(Sidekiq::Queue, size: 0) }

  before do
    allow(Sidekiq::Queue).to receive(:new).with("low").and_return(job_queue)
  end

  def enqueued_user_ids
    GenerateAvatarVariantJob.jobs.map { _1["args"].first }
  end

  it "enqueues a user whose avatar only has variants of an older size" do
    user = create(:user, :with_avatar)
    blob = user.avatar.blob
    blob.variant_records.create!(variation_digest: blob.variant(resize_to_limit: [128, 128]).variation.digest)
    GenerateAvatarVariantJob.jobs.clear

    expect(described_class.process(start_id: user.id)).to eq(enqueued: 1, skipped: 0)
    expect(enqueued_user_ids).to eq([user.id])
  end

  it "skips a user whose 400x400 variant is already processed, so re-running costs nothing" do
    user = create(:user, :with_avatar)
    user.avatar_variant
    GenerateAvatarVariantJob.jobs.clear

    expect(described_class.process(start_id: user.id)).to eq(enqueued: 0, skipped: 1)
    expect(GenerateAvatarVariantJob.jobs.size).to eq(0)
  end

  it "ignores a user's attachments other than the avatar" do
    user = create(:user, :with_subscribe_preview)
    GenerateAvatarVariantJob.jobs.clear

    expect(described_class.process(start_id: user.id)).to eq(enqueued: 0, skipped: 0)
    expect(GenerateAvatarVariantJob.jobs.size).to eq(0)
  end

  it "enqueues every eligible user across multiple batches" do
    users = create_list(:user, 2, :with_avatar)
    GenerateAvatarVariantJob.jobs.clear

    expect(described_class.process(start_id: users.first.id, batch_size: 1)).to eq(enqueued: 2, skipped: 0)
    expect(enqueued_user_ids).to match_array(users.map(&:id))
  end

  it "stops at end_id even partway through a batch" do
    users = create_list(:user, 2, :with_avatar)
    GenerateAvatarVariantJob.jobs.clear

    expect(described_class.process(start_id: users.first.id, end_id: users.first.id)).to eq(enqueued: 1, skipped: 0)
    expect(enqueued_user_ids).to eq([users.first.id])
  end

  it "waits for the low queue to drain before enqueuing another batch" do
    user = create(:user, :with_avatar)
    GenerateAvatarVariantJob.jobs.clear
    allow(job_queue).to receive(:size).and_return(described_class::MAX_QUEUED_JOBS, 0)
    backfill = described_class.new
    allow(backfill).to receive(:sleep)

    expect(backfill.process(start_id: user.id)).to eq(enqueued: 1, skipped: 0)
    expect(backfill).to have_received(:sleep).with(described_class::QUEUE_POLL_SECONDS).once
  end
end
