# frozen_string_literal: true

require "spec_helper"

describe SendWorkflowEmailsToOpenedNonClickersJob, :freeze_time do
  before do
    @seller = create(:user)
    @product = create(:product, user: @seller)
    @watched_post = create(:published_installment, seller: @seller, link: @product)
    @workflow = create(:workflow, seller: @seller, link: @product, workflow_trigger: Workflow::OPENED_NO_CLICK_WORKFLOW_TRIGGER,
                                  workflow_trigger_post_id: @watched_post.external_id)
    @installment = create(:published_installment, link: @product, workflow: @workflow,
                                                  workflow_trigger: Workflow::OPENED_NO_CLICK_WORKFLOW_TRIGGER)
    @rule = create(:installment_rule, installment: @installment, delayed_delivery_time: 3.days)
    @purchase = create(:purchase, link: @product, seller: @seller)
  end

  def stub_engagement(opens, clicked: [])
    allow(EmailEngagementDynamoStore).to receive(:purchase_open_records).with(@watched_post.id, opened_after: anything, opened_before: anything).and_return(opens)
    allow(EmailEngagementDynamoStore).to receive(:clicked_recipient_digests).with(@watched_post.id).and_return(clicked)
  end

  def opener(first_open_at:, digest: "digest-1", purchase_id: @purchase.id)
    { purchase_id:, recipient_digest: digest, first_open_at: }
  end

  it "queues one send for an opener whose delay has elapsed" do
    stub_engagement([opener(first_open_at: 4.days.ago)])

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob).to have_enqueued_sidekiq_job(@installment.id, @rule.version, @purchase.id, "digest-1")
  end

  it "waits for each recipient's own open rather than for a blast" do
    stub_engagement([opener(first_open_at: 1.day.ago)])

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs).to be_empty
  end

  it "leaves out the recipients who have clicked" do
    stub_engagement([opener(first_open_at: 4.days.ago)], clicked: ["digest-1"])

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs).to be_empty
  end

  it "only covers the opens inside its window" do
    stub_engagement([opener(first_open_at: 30.days.ago)])

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs).to be_empty
  end

  it "covers the opens that are already due when it is asked to look back indefinitely" do
    stub_engagement([opener(first_open_at: 30.days.ago, digest: "old")])

    described_class.new.perform(@installment.id, nil)

    expect(SendWorkflowEmailToOpenedNonClickerJob).to have_enqueued_sidekiq_job(@installment.id, @rule.version, @purchase.id, "old")
  end

  it "does nothing when the watched email is no longer one of the seller's sent posts" do
    @watched_post.mark_deleted!
    stub_engagement([opener(first_open_at: 4.days.ago)])

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs).to be_empty
  end

  it "does nothing when the workflow has been deleted" do
    @workflow.mark_deleted!
    stub_engagement([opener(first_open_at: 4.days.ago)])

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs).to be_empty
  end

  it "does nothing when the installment is unpublished" do
    @installment.update!(published_at: nil)
    stub_engagement([opener(first_open_at: 4.days.ago)])

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs).to be_empty
  end

  it "defers the scan when the seller is over the daily large-send ceiling" do
    stub_engagement([opener(first_open_at: 4.days.ago)])
    allow(SellerLargeBlastQuota).to receive(:allow?).and_return(false)
    allow(SellerLargeBlastQuota).to receive(:deferred_run_at).and_return(6.hours.from_now)

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs).to be_empty
    expect(described_class).to have_enqueued_sidekiq_job(@installment.id, nil, 5.days.ago.iso8601, nil).at(6.hours.from_now)
  end

  it "keeps the publish's rule version on a scan it defers" do
    stub_engagement([opener(first_open_at: 4.days.ago)])
    allow(SellerLargeBlastQuota).to receive(:allow?).and_return(false)
    allow(SellerLargeBlastQuota).to receive(:deferred_run_at).and_return(6.hours.from_now)

    described_class.new.perform(@installment.id, nil, nil, @rule.version)

    expect(described_class).to have_enqueued_sidekiq_job(@installment.id, nil, nil, @rule.version).at(6.hours.from_now)
  end

  it "reads the publish's scan from the primary and retries while the rule version is not visible" do
    stub_engagement([opener(first_open_at: 4.days.ago)])
    expect(ApplicationRecord).to receive(:connected_to).with(role: :writing).and_call_original

    expect do
      described_class.new.perform(@installment.id, nil, nil, @rule.version + 1)
    end.to raise_error(described_class::RuleNotCommittedError)
    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs).to be_empty
  end

  it "does not retry a pinned scan whose installment was unpublished" do
    @installment.update!(published_at: nil)
    stub_engagement([opener(first_open_at: 4.days.ago)])

    expect { described_class.new.perform(@installment.id, nil, nil, @rule.version + 1) }.not_to raise_error
  end

  it "covers every open since a fixed time when it is given one, as after a deferral or a delay edit" do
    stub_engagement([opener(first_open_at: 8.days.ago, digest: "recovered"), opener(first_open_at: 12.days.ago, digest: "too-old")])

    described_class.new.perform(@installment.id, nil, 10.days.ago.iso8601)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs.map { _1["args"].last }).to eq(["recovered"])
  end

  it "asks the store for only the opens inside its window" do
    stub_engagement([])

    described_class.new.perform(@installment.id)

    expect(EmailEngagementDynamoStore).to have_received(:purchase_open_records).with(@watched_post.id, opened_after: 5.days.ago, opened_before: 3.days.ago)
  end

  it "does not read clicks when no open is due" do
    stub_engagement([opener(first_open_at: 1.day.ago)])

    described_class.new.perform(@installment.id)

    expect(EmailEngagementDynamoStore).not_to have_received(:clicked_recipient_digests)
  end

  it "claims the daily slot with the recipient count it is about to queue" do
    allow(SellerLargeBlastQuota).to receive(:allow?).and_call_original
    stub_engagement([opener(first_open_at: 4.days.ago), opener(first_open_at: 5.days.ago, digest: "digest-2")])

    described_class.new.perform(@installment.id)

    expect(SellerLargeBlastQuota).to have_received(:allow?).with(
      seller_id: @seller.id, kind: "workflow", blast_id: @installment.id, recipient_count: 2
    )
  end

  it "counts only the opens the previous daily scan did not cover toward the daily slot" do
    allow(SellerLargeBlastQuota).to receive(:allow?).and_call_original
    stub_engagement([opener(first_open_at: 3.days.ago - 1.hour), opener(first_open_at: 4.days.ago - 1.hour, digest: "digest-2")])

    described_class.new.perform(@installment.id)

    expect(SellerLargeBlastQuota).to have_received(:allow?).with(
      seller_id: @seller.id, kind: "workflow", blast_id: @installment.id, recipient_count: 1
    )
    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs.size).to eq(2)
  end

  it "leaves out the opens from before a new-customers-only email went live" do
    @installment.update!(is_for_new_customers_of_workflow: true, published_at: 4.5.days.ago)
    stub_engagement([opener(first_open_at: 4.days.ago, digest: "after"), opener(first_open_at: 4.8.days.ago, digest: "before")])

    described_class.new.perform(@installment.id, nil)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs.map { _1["args"].last }).to eq(["after"])
  end

  it "covers the opens from before the email went live when it is not for new customers only" do
    @installment.update!(published_at: 4.5.days.ago)
    stub_engagement([opener(first_open_at: 4.8.days.ago, digest: "before")])

    described_class.new.perform(@installment.id, nil)

    expect(SendWorkflowEmailToOpenedNonClickerJob).to have_enqueued_sidekiq_job(@installment.id, @rule.version, @purchase.id, "before")
  end

  it "defers the scan while the seller already has a fanout in flight" do
    stub_engagement([opener(first_open_at: 4.days.ago)])
    allow(WorkflowSellerFanoutLock).to receive(:acquire).and_return(nil)
    allow(WorkflowSellerFanoutLock).to receive(:retry_in).and_return(30.seconds)

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs).to be_empty
    expect(described_class.jobs.size).to eq(1)
    expect(described_class.jobs.first["args"]).to eq([@installment.id, nil, 5.days.ago.iso8601, nil])
    expect(described_class.jobs.first["at"]).to be_within(2.seconds).of(30.seconds.from_now.to_f)
  end

  it "keeps the publish's rule version and open bound on a scan deferred behind the seller's fanout" do
    stub_engagement([opener(first_open_at: 4.days.ago)])
    allow(WorkflowSellerFanoutLock).to receive(:acquire).and_return(nil)
    allow(WorkflowSellerFanoutLock).to receive(:retry_in).and_return(30.seconds)

    described_class.new.perform(@installment.id, nil, 10.days.ago.iso8601, @rule.version)

    expect(described_class.jobs.sole["args"]).to eq([@installment.id, nil, 10.days.ago.iso8601, @rule.version])
  end

  it "defers the scan without reading the opens while the seller's fanout lock is held" do
    stub_engagement([opener(first_open_at: 4.days.ago)])
    allow(WorkflowSellerFanoutLock).to receive(:held?).with(@seller.id).and_return(true)
    allow(WorkflowSellerFanoutLock).to receive(:retry_in).and_return(30.seconds)

    described_class.new.perform(@installment.id)

    expect(EmailEngagementDynamoStore).not_to have_received(:purchase_open_records)
    expect(described_class.jobs.sole["args"]).to eq([@installment.id, nil, 5.days.ago.iso8601, nil])
    expect(described_class.jobs.sole["at"]).to be_within(2.seconds).of(30.seconds.from_now.to_f)
  end

  it "releases the seller's fanout lock once the sends are handed over" do
    stub_engagement([opener(first_open_at: 4.days.ago)])
    lock = instance_double(WorkflowSellerFanoutLock)
    allow(WorkflowSellerFanoutLock).to receive(:acquire).and_return(lock)
    expect(lock).to receive(:release)

    described_class.new.perform(@installment.id)
  end

  it "releases the seller's fanout lock when the scan raises" do
    stub_engagement([opener(first_open_at: 4.days.ago)])
    lock = instance_double(WorkflowSellerFanoutLock)
    allow(WorkflowSellerFanoutLock).to receive(:acquire).and_return(lock)
    allow(SellerLargeBlastQuota).to receive(:allow?).and_return(false)
    allow(SellerLargeBlastQuota).to receive(:deferred_run_at).and_return(6.hours.from_now)
    allow(described_class).to receive(:perform_at).and_raise("redis down")
    expect(lock).to receive(:release)

    expect { described_class.new.perform(@installment.id) }.to raise_error("redis down")
  end

  context "with a large batch" do
    before do
      $redis.set(RedisKey.workflow_immediate_fanout_threshold, 3)
      $redis.set(RedisKey.workflow_immediate_enqueue_per_second, 1)
    end

    after do
      $redis.del(RedisKey.workflow_immediate_fanout_threshold, RedisKey.workflow_immediate_enqueue_per_second, RedisKey.workflow_immediate_fanout_max_spread_seconds)
    end

    def run_at_by_digest
      SendWorkflowEmailToOpenedNonClickerJob.jobs.to_h { [_1["args"].last, _1["at"]&.round(3)] }
    end

    it "spreads the sends out at the configured rate instead of making every one runnable at once" do
      stub_engagement(%w[a b c].map { opener(first_open_at: 4.days.ago, digest: _1) })

      described_class.new.perform(@installment.id)

      expect(run_at_by_digest).to eq("a" => nil, "b" => 1.second.from_now.to_f.round(3), "c" => 2.seconds.from_now.to_f.round(3))
    end

    it "speeds up to fit the batch inside the maximum spread rather than clumping the tail at the end" do
      $redis.set(RedisKey.workflow_immediate_fanout_max_spread_seconds, 1)
      stub_engagement(%w[a b c d].map { opener(first_open_at: 4.days.ago, digest: _1) })

      described_class.new.perform(@installment.id)

      expect(run_at_by_digest.values).to eq([nil] + [0.25, 0.5, 0.75].map { (Time.current + _1).to_f.round(3) })
    end

    it "leaves a batch under the threshold unpaced" do
      stub_engagement(%w[a b].map { opener(first_open_at: 4.days.ago, digest: _1) })

      described_class.new.perform(@installment.id)

      expect(run_at_by_digest.values).to all(be_nil)
    end
  end

  it "raises when Sidekiq does not enqueue a send" do
    stub_engagement([opener(first_open_at: 4.days.ago)])
    allow(SendWorkflowEmailToOpenedNonClickerJob).to receive(:perform_async).and_return(nil)

    expect { described_class.new.perform(@installment.id) }.to raise_error("Sidekiq did not enqueue the opened-no-click send")
  end
end
