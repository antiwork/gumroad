# frozen_string_literal: true

require "spec_helper"
require "timeout"

# The old Gumroad newsletter can send while it has no cutover row yet. A send that began then still has to be
# ordered against the row being created and the newsletter retiring before the provider call. In tests the
# provider call is the logged no-op inside the provider API; nothing leaves the process.
describe "Old Gumroad newsletter sends that began before its cutover row existed", :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements }

  before do
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    # The only reader has no account, and a synthetic decision covers that, so retire! itself can succeed.
    stub_const("#{migration}::RETIREMENT_RESOLUTIONS", { guest: "synthetic test decision" }.freeze)
    @newsletter = create(:named_user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) }
    @reader = create(:follower, user: @newsletter, email: "creation-handoff-reader@example.com", source: Follower::From::EMBED_FORM,
                                confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    @other_seller = create(:named_user)
    create(:active_follower, user: @other_seller, email: "creation-other-reader@example.com")
  end

  after do
    sellers = [@newsletter, @other_seller]
    FeatureAnnouncementNewsletterCutover.where(seller_id: @newsletter.id).delete_all
    posts = Installment.where(seller_id: sellers.map(&:id))
    installment_ids = posts.ids
    SentPostEmail.where(post_id: posts.select(:id)).delete_all
    EmailInfo.where(installment_id: posts.select(:id)).delete_all
    PostEmailBlast.where(post_id: posts.select(:id)).delete_all
    InstallmentRule.where(installment_id: posts.select(:id)).delete_all
    UrlRedirect.where(installment_id: posts.select(:id)).delete_all
    posts.delete_all
    Workflow.where(seller_id: sellers.map(&:id)).delete_all
    Follower.where(followed_id: sellers.map(&:id)).delete_all
    Purchase.where(seller_id: sellers.map(&:id)).delete_all
    product_ids = Link.where(user_id: sellers.map(&:id)).ids
    Link.where(id: product_ids).delete_all
    AudienceMember.where(seller_id: sellers.map(&:id)).delete_all
    sellers.each(&:destroy!)
    delete_leftovers(user_ids: sellers.map(&:id), product_ids:, installment_ids:)
  end

  def cutover = FeatureAnnouncementNewsletterCutover.find_by(seller_id: @newsletter.id)

  def in_thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  def finish(*threads)
    threads.compact.each { _1.join(15) }
  rescue Timeout::Error, StandardError
    nil
  end

  def lock_waits = ActiveRecord::Base.connection.uncached { ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM performance_schema.data_lock_waits") }.to_i

  def waited_for_lock?
    Timeout.timeout(5) { sleep 0.05 until lock_waits > 0 }
    true
  rescue Timeout::Error
    false
  end

  def cutover!
    migration.prepare!(cutoff_at: 1.hour.ago)
    migration.apply!(confirmed_eligible_count: 0)
    migration.retire!
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

  # Pauses a provider API once it has its admission, while it renders the message, until released.
  def pause_preparation(api, method)
    paused = Queue.new
    release = Queue.new
    allow_any_instance_of(api).to receive(method).and_wrap_original do |original, *args|
      paused << true
      Timeout.timeout(20) { release.pop }
      original.call(*args)
    end
    [paused, release]
  end

  def use_resend
    allow(Feature).to receive(:inactive?).and_call_original
    allow(Feature).to receive(:inactive?).with(:use_resend_for_post_emails, anything).and_return(false)
    allow(Feature).to receive(:active?).and_call_original
    allow(Feature).to receive(:active?).with(:force_resend_for_post_emails, anything).and_return(true)
  end

  {
    "SendGrid" => [PostSendgridApi, :build_mail],
    "Resend" => [PostResendApi, :build_emails],
  }.each do |provider, (api, preparation)|
    it "refuses a #{provider} blast slice at the handoff when the cutover is created and retired while it renders" do
      use_resend if api == PostResendApi
      blast = blast_for(@newsletter)
      paused, release = pause_preparation(api, preparation)
      sending = in_thread { send_blast(blast) }
      Timeout.timeout(10) { paused.pop }

      cutover!
      release << true
      sending.value

      expect(cutover.state).to eq("retired")
      expect(sent_to(blast.post)).to be_empty
      expect(blast.reload.attributes.slice("expiry_reason", "completed_at", "delivery_count"))
        .to eq("expiry_reason" => "newsletter_retired", "completed_at" => nil, "delivery_count" => 0)
      expect(blast.delivery_status).to eq("stopped")
    ensure
      finish(sending)
    end
  end

  it "refuses a workflow email at the handoff when the cutover is created and retired while it renders, leaving no record of a send" do
    post = workflow_post
    paused, release = pause_preparation(PostSendgridApi, :build_mail)
    sending = in_thread { send_workflow(post) }
    Timeout.timeout(10) { paused.pop }

    cutover!
    release << true
    sending.value

    expect(cutover.state).to eq("retired")
    expect(sent_to(post)).to be_empty
  ensure
    finish(sending)
  end

  it "makes prepare! wait for a handoff already under way, which finishes and keeps what it delivered, while other sends go on" do
    blast = blast_for(@newsletter)
    in_handoff = Queue.new
    release = Queue.new
    # The test-env provider call: log a delivery that would have gone out.
    allow(Rails.logger).to receive(:info).and_wrap_original do |original, message = nil, *args, &block|
      if message.to_s.include?("Would have sent post #{blast.post.id} ")
        in_handoff << true
        Timeout.timeout(20) { release.pop }
      end
      original.call(message, *args, &block)
    end
    sending = in_thread { send_blast(blast) }
    Timeout.timeout(10) { in_handoff.pop }

    preparing = in_thread { migration.prepare!(cutoff_at: 1.hour.ago) }
    expect(waited_for_lock?).to be(true)
    expect(FeatureAnnouncementNewsletterCutover.exists?(seller_id: @newsletter.id)).to be(false)
    other_blast = blast_for(@other_seller)
    product = create(:product, user: @newsletter)
    create(:purchase, link: product, email: "creation-customer@example.com")
    product_blast = create(:blast, :just_requested, post: create(:product_post, :published, seller: @newsletter, link: product))
    Timeout.timeout(10) do
      send_blast(other_blast)
      send_blast(product_blast)
    end
    expect([sent_to(other_blast.post), sent_to(product_blast.post)]).to eq([["creation-other-reader@example.com"], ["creation-customer@example.com"]])
    expect(preparing).to be_alive
    release << true

    sending.value
    preparing.value
    expect(cutover.state).to eq("prepared")
    expect(sent_to(blast.post)).to eq([@reader.email])
    expect(blast.reload.attributes.slice("expiry_reason", "delivery_count")).to eq("expiry_reason" => nil, "delivery_count" => 1)
    expect(blast.completed_at).to be_present
  ensure
    finish(sending, preparing)
  end
end
