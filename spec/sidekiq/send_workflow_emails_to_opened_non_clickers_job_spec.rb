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
    allow(EmailEngagementDynamoStore).to receive(:purchase_open_records).with(@watched_post.id).and_return(opens)
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
    expect(described_class).to have_enqueued_sidekiq_job(@installment.id, 2.days.to_i).at(6.hours.from_now)
  end

  it "claims the daily slot with the recipient count it is about to queue" do
    allow(SellerLargeBlastQuota).to receive(:allow?).and_call_original
    stub_engagement([opener(first_open_at: 4.days.ago), opener(first_open_at: 5.days.ago, digest: "digest-2")])

    described_class.new.perform(@installment.id)

    expect(SellerLargeBlastQuota).to have_received(:allow?).with(
      seller_id: @seller.id, kind: "workflow", blast_id: @installment.id, recipient_count: 2
    )
  end

  it "leaves out the openers who were already there when the workflow was published" do
    @workflow.update!(send_to_past_customers: false, first_published_at: 4.days.ago)
    stub_engagement([
                      opener(first_open_at: 5.days.ago, digest: "before-publication"),
                      opener(first_open_at: 3.days.ago, digest: "after-publication"),
                    ])

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs.map { |job| job["args"].last }).to eq(["after-publication"])
  end

  it "covers the opens from before the publication when the workflow asks for past openers" do
    @workflow.update!(send_to_past_customers: true, first_published_at: 4.days.ago)
    stub_engagement([opener(first_open_at: 5.days.ago, digest: "before-publication")])

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob).to have_enqueued_sidekiq_job(@installment.id, @rule.version, @purchase.id, "before-publication")
  end

  it "defers the scan while the seller already has a fanout in flight" do
    stub_engagement([opener(first_open_at: 4.days.ago)])
    allow(WorkflowSellerFanoutLock).to receive(:acquire).and_return(nil)
    allow(WorkflowSellerFanoutLock).to receive(:retry_in).and_return(30.seconds)

    described_class.new.perform(@installment.id)

    expect(SendWorkflowEmailToOpenedNonClickerJob.jobs).to be_empty
    expect(described_class.jobs.size).to eq(1)
    expect(described_class.jobs.first["at"]).to be_within(2.seconds).of(30.seconds.from_now.to_f)
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

  it "releases a large fanout over time instead of queueing every send at once" do
    stub_engagement((1..90).map { |index| opener(first_open_at: 4.days.ago, digest: "digest-#{index}") })

    described_class.new.perform(@installment.id)

    jobs = SendWorkflowEmailToOpenedNonClickerJob.jobs
    expect(jobs.size).to eq(90)
    expect(jobs.count { |job| job["at"].present? }).to be > 0
  end
end
