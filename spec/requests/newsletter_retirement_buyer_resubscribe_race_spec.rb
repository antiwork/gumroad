# frozen_string_literal: true

require "spec_helper"
require "timeout"

# A buyer opt-out counts as resolved when retire! scans. Resubscribing lifts it, so the resubscribe and
# retirement have to be ordered against each other.
describe "Resubscribing as a buyer while the old Gumroad newsletter retires", type: :request do
  self.use_transactional_tests = false

  let(:migration) { Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements }

  before do
    host! DOMAIN
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    @newsletter = create(:user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) }
    @buyer = create(:user, email: "resubscribing-buyer@example.com")
    @follow = create(:follower, user: @newsletter, email: @buyer.email, follower_user_id: @buyer.id, source: Follower::From::EMBED_FORM,
                                confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    @purchase = create(:purchase, link: create(:product, user: @newsletter), email: @buyer.email, can_contact: false)
    @other_seller = create(:user)
    @other_purchase = create(:purchase, link: create(:product, user: @other_seller), email: @buyer.email, can_contact: false)
    migration.prepare!(cutoff_at: 1.hour.ago)
    migration.apply!(confirmed_eligible_count: 0) # the only follow is a buyer who opted out
    # Last changed long before retire! starts, so only the resubscribe itself can put it in the recheck.
    @follow.update_columns(updated_at: 1.hour.ago)
  end

  after do
    FeatureAnnouncementNewsletterCutover.where(seller_id: @newsletter.id).delete_all
    FeatureAnnouncementSubscription.where(user_id: @buyer.id).delete_all
    Follower.where(followed_id: @newsletter.id).delete_all
    sellers = [@newsletter, @other_seller].compact
    Purchase.where(seller_id: sellers.map(&:id)).delete_all
    Link.where(user_id: sellers.map(&:id)).delete_all
    AudienceMember.where(seller_id: sellers.map(&:id)).delete_all # delete_all skips the callbacks that remove these
    [@buyer, *sellers].each(&:destroy!)
  end

  def cutover = FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id)

  def resubscribe(purchase) = post(subscribe_purchase_path(purchase.external_id))

  def in_thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  # Without the lock under test, the helper times out waiting; joining it must not hide the assertion that failed.
  def finish(thread)
    thread&.join(10)
  rescue Timeout::Error, StandardError
    nil
  end

  # information_schema.innodb_trx is refreshed at most every 0.1s, so poll slower than that. Uncached, since
  # inside a request the query cache would keep returning the first answer.
  def wait_for_lock_wait(connection)
    Timeout.timeout(10) do
      sleep 0.25 until connection.uncached { connection.select_value("SELECT COUNT(*) FROM information_schema.innodb_trx WHERE trx_state = 'LOCK WAIT'") }.to_i > 0
    end
  end

  it "makes retire! wait for a resubscribe already holding the cutover row, then refuses with the buyer counted" do
    fenced = Queue.new
    allow(FeatureAnnouncementNewsletterCutover).to receive(:fence_buyer_resubscribe).and_wrap_original do |original, *args|
      original.call(*args)
      fenced << true
      wait_for_lock_wait(ActiveRecord::Base.connection)
    end
    retirement = in_thread do
      Timeout.timeout(10) { fenced.pop }
      migration.retire!
    end

    resubscribe(@purchase)

    expect { retirement.value }.to raise_error(migration::CoverageIncomplete)
    expect(cutover.state).to eq("migrated")
    expect(cutover.retirement_coverage["unresolved"]).to include("eligible" => 1)
    expect(@purchase.reload.can_contact).to be(true)
  ensure
    finish(retirement)
  end

  it "makes a resubscribe wait for retire! holding the cutover row; it then completes and leaves Feature announcements alone" do
    holding = Queue.new
    allow_any_instance_of(migration).to receive(:retirement_coverage).and_wrap_original do |original, *args|
      holding << true
      wait_for_lock_wait(ActiveRecord::Base.connection)
      original.call(*args)
    end
    retirement = in_thread { migration.retire! }
    Timeout.timeout(10) { holding.pop }

    resubscribe(@other_purchase) # another creator's resubscribe takes no newsletter lock
    expect(@other_purchase.reload.can_contact).to be(true)
    expect(retirement).to be_alive
    resubscribe(@purchase)

    expect(@purchase.reload.can_contact).to be(true)
    retirement.value
    expect(cutover.state).to eq("retired")
    expect(FeatureAnnouncementSubscription.where(user_id: @buyer.id)).to be_empty
  ensure
    finish(retirement)
  end

  [false, true].each do |fallback|
    it "catches a resubscribe committed while retire!'s scan runs#{" through the save without validations" if fallback}" do
      scanned = Queue.new
      resubscribed = Queue.new
      allow_any_instance_of(migration).to receive(:outcome_counts).and_wrap_original do |original, *args|
        original.call(*args).tap do
          next unless args.last == Follower.all

          scanned << true
          Timeout.timeout(10) { resubscribed.pop }
        end
      end
      retirement = in_thread { migration.retire! }
      Timeout.timeout(10) { scanned.pop }
      # Rows that fail today's validations take the controller's save(validate: false) path.
      allow_any_instance_of(Purchase).to receive(:valid?).and_return(false) if fallback

      resubscribe(@purchase)
      resubscribed << true

      expect(@purchase.reload.can_contact).to be(true)
      expect { retirement.value }.to raise_error(migration::CoverageIncomplete)
      expect(cutover.state).to eq("migrated")
      expect(cutover.retirement_coverage["changed_during_scan"]).to include("eligible" => 1)
    ensure
      finish(retirement)
    end
  end
end
