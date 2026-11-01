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
end
