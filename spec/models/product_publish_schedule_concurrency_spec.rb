# frozen_string_literal: true

require "spec_helper"

describe ProductPublishSchedule, "across connections" do
  self.use_transactional_tests = false

  let!(:seller) { create(:user, timezone: "Pacific Time (US & Canada)") }
  let!(:product) { create(:product, user: seller, draft: true) }
  let!(:schedule) { create(:product_publish_schedule, product:, scheduled_by: seller, publish_at: 1.minute.ago) }

  after do
    product_ids = Link.where(user_id: seller.id).ids
    ProductPublishSchedule.where(product_id: product_ids).delete_all
    Price.where(link_id: product_ids).delete_all
    Link.where(id: product_ids).delete_all
    RefundPolicy.where(seller_id: seller.id).delete_all
    UserComplianceInfo.where(user_id: seller.id).delete_all
    GlobalAffiliate.where(affiliate_user_id: seller.id).delete_all
    User.where(id: seller.id).delete_all
  end

  # The tagged thread stops at `hit` until the test calls `open`.
  let(:gate_class) do
    Class.new do
      def initialize = (@reached, @released = Queue.new, Queue.new)
      def hit = (@reached << true) && @released.pop
      def wait = @reached.pop(timeout: 10) || raise("gate never reached")
      def open = @released << true
    end
  end

  def in_thread(tag, &block)
    Thread.new do
      Thread.current[tag] = true
      ActiveRecord::Base.connection_pool.with_connection(&block)
    rescue StandardError => e
      e
    end
  end

  def run_job = PublishScheduledProductJob.new.perform(schedule.id)

  def pause_job_before_publish(gate)
    allow_any_instance_of(Link).to receive(:publish!).and_wrap_original do |original, *args, **kwargs, &block|
      gate.hit if Thread.current[:job]
      original.call(*args, **kwargs, &block)
    end
  end

  it "does not publish a draft that another connection archives after the job's checks" do
    publishing = gate_class.new
    pause_job_before_publish(publishing)

    job = in_thread(:job) { run_job }
    publishing.wait
    Link.find(product.id).update!(archived: true, purchase_disabled_at: Time.current)
    publishing.open
    expect(job.join(10)).to eq(job)
    expect(job.value).not_to be_a(Exception)

    expect(product.reload).to have_attributes(draft: true, archived?: true, purchase_disabled_at: be_present)
    expect(described_class.exists?(schedule.id)).to eq(false)
    expect(SendProductPublishScheduleNoticeJob.jobs.size).to eq(0)
  end

  it "does not resurrect a draft that another connection deletes after the job's checks" do
    publishing = gate_class.new
    pause_job_before_publish(publishing)

    job = in_thread(:job) { run_job }
    publishing.wait
    Link.find(product.id).delete!
    publishing.open
    expect(job.join(10)).to eq(job)
    expect(job.value).not_to be_a(Exception)

    expect(product.reload).to have_attributes(draft: true, deleted_at: be_present)
    expect(described_class.exists?(schedule.id)).to eq(false)
  end

  it "makes an archive that arrives while the job holds the product lock wait, then apply to the published product" do
    fenced = gate_class.new
    allow(described_class).to receive(:withdrawn?).and_wrap_original do |original, *args|
      original.call(*args).tap { fenced.hit if Thread.current[:job] && Link.connection.transaction_open? }
    end

    job = in_thread(:job) { run_job }
    fenced.wait
    archive = in_thread(:archive) { Link.find(product.id).update!(archived: true) }
    sleep 0.3
    expect(archive).to be_alive
    fenced.open
    [job, archive].each { expect(_1.join(10)).to eq(_1) }
    expect([job.value, archive.value]).to all(satisfy { !_1.is_a?(Exception) })

    expect(schedule.reload.status).to eq("published")
    expect(product.reload).to have_attributes(draft: false, archived?: true)
  end

  it "keeps the product row unlocked while content moderation runs" do
    moderating = gate_class.new
    allow(ContentModeration::ModerateRecordService).to receive(:check).and_wrap_original do |original, *args, **kwargs|
      moderating.hit if Thread.current[:job]
      original.call(*args, **kwargs)
    end

    job = in_thread(:job) { run_job }
    moderating.wait
    expect { Link.transaction { Link.where(id: product.id).lock("FOR UPDATE NOWAIT").pick(:id) } }.not_to raise_error
    moderating.open
    expect(job.join(10)).to eq(job)
    expect(schedule.reload.status).to eq("published")
  end
end
