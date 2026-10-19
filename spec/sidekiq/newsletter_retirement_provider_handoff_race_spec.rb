# frozen_string_literal: true

require "spec_helper"
require "timeout"

# The retirement checks before a send are plain reads, so retire! can commit between one and the provider
# call. The handoff itself is ordered against retire!: one already admitted finishes first, and one that
# arrives after retirement is refused before anything reaches the provider. In tests the provider call is
# the logged no-op inside PostSendgridApi; nothing leaves the process.
describe "Old Gumroad newsletter sends reaching the provider while it retires" do
  self.use_transactional_tests = false

  let(:migration) { Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements }

  before do
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    # The only reader has no account, and a synthetic decision covers that, so retire! itself can succeed.
    stub_const("#{migration}::RETIREMENT_RESOLUTIONS", { guest: "synthetic test decision" }.freeze)
    @newsletter = create(:named_user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) }
    @reader = create(:follower, user: @newsletter, email: "handoff-reader@example.com", source: Follower::From::EMBED_FORM,
                                confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    @other_seller = create(:named_user)
    create(:active_follower, user: @other_seller, email: "other-reader@example.com")
    migration.prepare!(cutoff_at: 1.hour.ago)
    migration.apply!(confirmed_eligible_count: 0)
  end

  after do
    sellers = [@newsletter, @other_seller]
    FeatureAnnouncementNewsletterCutover.where(seller_id: @newsletter.id).delete_all
    posts = Installment.where(seller_id: sellers.map(&:id))
    SentPostEmail.where(post_id: posts.select(:id)).delete_all
    EmailInfo.where(installment_id: posts.select(:id)).delete_all
    PostEmailBlast.where(post_id: posts.select(:id)).delete_all
    InstallmentRule.where(installment_id: posts.select(:id)).delete_all
    UrlRedirect.where(installment_id: posts.select(:id)).delete_all
    posts.delete_all
    Workflow.where(seller_id: sellers.map(&:id)).delete_all
    Follower.where(followed_id: sellers.map(&:id)).delete_all
    AudienceMember.where(seller_id: sellers.map(&:id)).delete_all
    sellers.each(&:destroy!)
  end

  def cutover = FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id)

  def in_thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  # Without the lock under test, the helper times out waiting; joining it must not hide the assertion that failed.
  def finish(*threads)
    threads.compact.each { _1.join(10) }
  rescue Timeout::Error, StandardError
    nil
  end

  # performance_schema is live, unlike information_schema.innodb_trx, whose cached copy can still show the previous
  # example's waiter. Uncached, since inside a request the query cache would keep returning the first answer.
  def wait_for_lock_wait(connection)
    Timeout.timeout(10) do
      sleep 0.05 until connection.uncached { connection.select_value("SELECT COUNT(*) FROM performance_schema.data_lock_waits") }.to_i > 0
    end
  end

  def blast_for(seller) = create(:blast, :just_requested, post: create(:audience_post, :published, seller:))

  def send_blast(blast) = SendPostBlastEmailsJob.new.perform(blast.id)

  def workflow_post
    workflow = create(:workflow, seller: @newsletter, link: nil, created_at: Time.current, workflow_type: Workflow::FOLLOWER_TYPE)
    create(:follower_installment, seller: @newsletter, workflow:, published_at: Time.current).tap do
      create(:installment_rule, installment: _1, delayed_delivery_time: 1.day)
    end
  end

  def send_workflow(post) = SendWorkflowInstallmentWorker.new.perform(post.id, post.installment_rule.version, nil, @reader.id, nil)

  def sent_to(post) = SentPostEmail.where(post_id: post.id).pluck(:email)

  # Holds retire! inside its final lock until another connection is waiting on the cutover row, or until released.
  def hold_retirement(release = nil)
    holding = Queue.new
    allow_any_instance_of(migration).to receive(:retirement_coverage).and_wrap_original do |original, *args|
      holding << true
      release ? Timeout.timeout(10) { release.pop } : wait_for_lock_wait(ActiveRecord::Base.connection)
      original.call(*args)
    end
    retirement = in_thread { migration.retire! }
    Timeout.timeout(10) { holding.pop }
    retirement
  end

  # Lets retire! commit once the send is past its plain retirement checks, just before the provider call.
  def retire_after(klass, method)
    release = Queue.new
    retirement = hold_retirement(release)
    allow_any_instance_of(klass).to receive(method).and_wrap_original do |original, *args, **kwargs, &block|
      release << true
      retirement.join(10)
      original.call(*args, **kwargs, &block)
    end
    retirement
  end

  # Pauses an admitted handoff, just before the provider call, until released.
  def pause_admitted_handoffs
    admitted = Queue.new
    release = Queue.new
    allow(FeatureAnnouncementNewsletterCutover).to receive(:admit_newsletter_handoff).and_wrap_original do |original, *args, &handoff|
      original.call(*args) do
        admitted << true
        Timeout.timeout(10) { release.pop }
        handoff.call
      end
    end
    [admitted, release]
  end

  describe "a blast" do
    it "is refused at the handoff when retire! commits after the slice passed its checks, and stops without anything accepted" do
      blast = blast_for(@newsletter)
      retirement = retire_after(SendPostBlastEmailsJob, :prepare_recipients)

      send_blast(blast)

      expect(sent_to(blast.post)).to be_empty
      expect(blast.reload.attributes.slice("expiry_reason", "completed_at", "delivery_count"))
        .to eq("expiry_reason" => "newsletter_retired", "completed_at" => nil, "delivery_count" => 0)
      expect(blast.delivery_status).to eq("stopped")
      expect($redis.exists?(RedisKey.blast_pending_recipients(blast.id))).to be(false)
      retirement.value
      expect(cutover.state).to eq("retired")
    ensure
      finish(retirement)
    end

    it "waits at the handoff while retire! holds the row, then is refused" do
      blast = blast_for(@newsletter)
      retirement = hold_retirement

      send_blast(blast)

      expect(sent_to(blast.post)).to be_empty
      expect(blast.reload.attributes.slice("expiry_reason", "delivery_count")).to eq("expiry_reason" => "newsletter_retired", "delivery_count" => 0)
      retirement.value
      expect(cutover.state).to eq("retired")
    ensure
      finish(retirement)
    end

    it "makes retire! wait for a handoff already admitted, which finishes and keeps what it delivered" do
      blast = blast_for(@newsletter)
      admitted, release = pause_admitted_handoffs
      sending = in_thread { send_blast(blast) }
      Timeout.timeout(10) { admitted.pop }

      retirement = in_thread { migration.retire! }
      wait_for_lock_wait(ActiveRecord::Base.connection)
      expect(retirement).to be_alive
      release << true

      sending.value
      retirement.value
      expect(cutover.state).to eq("retired")
      expect(sent_to(blast.post)).to eq([@reader.email])
      expect(blast.reload.attributes.slice("expiry_reason", "delivery_count")).to eq("expiry_reason" => nil, "delivery_count" => 1)
      expect(blast.completed_at).to be_present
    ensure
      finish(sending, retirement)
    end

    it "doesn't hold back another creator's blast or the seller's customer posts while retire! holds the row" do
      other_blast = blast_for(@other_seller)
      product = create(:product, user: @newsletter)
      create(:purchase, link: product, email: "newsletter-customer@example.com")
      product_blast = create(:blast, :just_requested, post: create(:product_post, :published, seller: @newsletter, link: product))
      release = Queue.new
      retirement = hold_retirement(release)

      Timeout.timeout(10) do
        send_blast(other_blast)
        send_blast(product_blast)
      end

      expect(retirement).to be_alive
      release << true
      retirement.value
      expect(sent_to(other_blast.post)).to eq(["other-reader@example.com"])
      expect(sent_to(product_blast.post)).to eq(["newsletter-customer@example.com"])
      expect(cutover.state).to eq("retired")
    ensure
      finish(retirement)
      Purchase.where(link_id: product&.id).delete_all
      Link.where(id: product&.id).delete_all
    end
  end

  describe "a workflow email" do
    it "is refused at the handoff when retire! commits after the worker's check, leaving no record of a send" do
      post = workflow_post
      retirement = retire_after(Installment, :send_email)

      send_workflow(post)

      expect(sent_to(post)).to be_empty
      retirement.value
      expect(cutover.state).to eq("retired")
    ensure
      finish(retirement)
    end

    it "waits at the handoff while retire! holds the row, then is refused" do
      post = workflow_post
      retirement = hold_retirement

      send_workflow(post)

      expect(sent_to(post)).to be_empty
      retirement.value
      expect(cutover.state).to eq("retired")
    ensure
      finish(retirement)
    end

    it "makes retire! wait for a handoff already admitted, which finishes and keeps its record" do
      post = workflow_post
      admitted, release = pause_admitted_handoffs
      sending = in_thread { send_workflow(post) }
      Timeout.timeout(10) { admitted.pop }

      retirement = in_thread { migration.retire! }
      wait_for_lock_wait(ActiveRecord::Base.connection)
      expect(retirement).to be_alive
      release << true

      sending.value
      retirement.value
      expect(cutover.state).to eq("retired")
      expect(sent_to(post)).to eq([@reader.email])
    ensure
      finish(sending, retirement)
    end
  end
end
