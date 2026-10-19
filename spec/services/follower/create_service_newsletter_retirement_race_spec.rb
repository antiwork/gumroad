# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Follower::CreateService checks retirement up front, outside the transaction that saves the follow, and a
# pending follow's confirmation request goes out later through FollowerMailer. Both the new pending row and
# that request have to be ordered against retire! as well.
describe Follower::CreateService, "while the old Gumroad newsletter retires", :aggregate_failures do
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  let(:migration) { Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements }
  let(:requester) { "pending-requester@example.com" }

  before do
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    @newsletter = create(:user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) }
    @other_seller = create(:user)
    migration.prepare!(cutoff_at: 1.hour.ago)
    migration.apply!(confirmed_eligible_count: 0)
    clear_enqueued_jobs
    ActionMailer::Base.deliveries.clear
  end

  after do
    sellers = [@newsletter, @other_seller]
    FeatureAnnouncementNewsletterCutover.where(seller_id: @newsletter.id).delete_all
    Follower.where(followed_id: sellers.map(&:id)).delete_all
    AudienceMember.where(seller_id: sellers.map(&:id)).delete_all # delete_all skips the callbacks that remove these
    sellers.each(&:destroy!)
    delete_leftovers(user_ids: sellers.map(&:id))
    clear_enqueued_jobs
  end

  def cutover = FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id)

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

  def request(seller, email) = described_class.perform(followed_user: seller, follower_email: email, follower_attributes: { source: Follower::From::EMBED_FORM })

  def confirmation_jobs(email)
    enqueued_jobs.select { _1[:args].first(2) == %w[FollowerMailer confirm_follower] }
      .select { Follower.find_by(id: _1[:args][3]["args"].last)&.email == email }
  end

  # Delivers the queued confirmation requests the way MailDeliveryJob does.
  def deliver_confirmations(email)
    confirmation_jobs(email).each { |job| FollowerMailer.confirm_follower(*job[:args][3]["args"]).deliver_now }
    ActionMailer::Base.deliveries.select { _1.to == [email] }
  end

  it "refuses a new follow, and queues no confirmation request, when retirement commits after the service's check" do
    retired = false
    allow(FeatureAnnouncementNewsletterCutover).to receive(:retired_for?).and_wrap_original do |original, seller_id|
      original.call(seller_id).tap do
        next if retired || seller_id != @newsletter.id

        retired = true
        in_thread { migration.retire! }.value
      end
    end

    result = request(@newsletter, requester)

    expect(cutover.state).to eq("retired")
    expect(Follower.where(followed_id: @newsletter.id, email: requester)).not_to exist
    expect(result.errors.full_messages).to include(Follower::RETIRED_NEWSLETTER_MESSAGE)
    expect(confirmation_jobs(requester)).to be_empty
  end

  it "reports the retirement, and queues no new confirmation request, when an existing pending follow is resubmitted as it commits" do
    pending_follow = request(@newsletter, requester)
    clear_enqueued_jobs
    retired = false
    allow(FeatureAnnouncementNewsletterCutover).to receive(:retired_for?).and_wrap_original do |original, seller_id|
      original.call(seller_id).tap do
        next if retired || seller_id != @newsletter.id

        retired = true
        in_thread { migration.retire! }.value
      end
    end

    result = request(@newsletter, requester)

    expect(cutover.state).to eq("retired")
    expect(result.id).to eq(pending_follow.id)
    expect(result.errors.full_messages).to include(Follower::RETIRED_NEWSLETTER_MESSAGE)
    expect(confirmation_jobs(requester)).to be_empty
  end

  it "makes retire! wait for a new follow being saved, and sends that follow no confirmation request once retired" do
    saved = Queue.new
    release = Queue.new
    allow_any_instance_of(Follower).to receive(:left_newsletter?).and_wrap_original do |original|
      if original.receiver.email == requester && original.receiver.previously_new_record?
        saved << true
        Timeout.timeout(20) { release.pop }
      end
      original.call
    end
    requesting = in_thread { request(@newsletter, requester) }
    Timeout.timeout(10) { saved.pop }

    retirement = in_thread { migration.retire! }
    expect(waited_for_lock?).to be(true)
    release << true
    requesting.value
    retirement.value

    expect(cutover.state).to eq("retired")
    expect(Follower.where(followed_id: @newsletter.id, email: requester, confirmed_at: nil)).to exist # pending before retirement
    expect(deliver_confirmations(requester)).to be_empty
  ensure
    finish(requesting, retirement)
  end

  it "makes retire! wait for a confirmation request already being handed to the mail provider, which goes out" do
    request(@newsletter, requester)
    in_handoff = Queue.new
    release = Queue.new
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_wrap_original do |original, mail|
      if mail.to == [requester]
        in_handoff << true
        Timeout.timeout(20) { release.pop }
      end
      original.call(mail)
    end
    sending = in_thread { deliver_confirmations(requester) }
    Timeout.timeout(10) { in_handoff.pop }

    retirement = in_thread { migration.retire! }
    expect(waited_for_lock?).to be(true)
    expect(retirement).to be_alive
    release << true

    expect(sending.value.size).to eq(1)
    retirement.value
    expect(cutover.state).to eq("retired")
  ensure
    finish(sending, retirement)
  end

  it "drops a confirmation request queued before retirement once retirement commits" do
    request(@newsletter, requester)
    expect(confirmation_jobs(requester).size).to eq(1)

    migration.retire!

    expect(deliver_confirmations(requester)).to be_empty
  end

  it "leaves another creator's follows and confirmation requests alone while retire! holds the cutover row" do
    holding = Queue.new
    release = Queue.new
    allow_any_instance_of(migration).to receive(:retirement_coverage).and_wrap_original do |original, *args|
      holding << true
      Timeout.timeout(20) { release.pop }
      original.call(*args)
    end
    retirement = in_thread { migration.retire! }
    Timeout.timeout(10) { holding.pop }

    Timeout.timeout(10) do
      expect(request(@other_seller, "other-requester@example.com")).to be_persisted
      expect(deliver_confirmations("other-requester@example.com").size).to eq(1)
    end
    expect(retirement).to be_alive
    release << true
    retirement.value
  ensure
    finish(retirement)
  end
end
