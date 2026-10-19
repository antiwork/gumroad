# frozen_string_literal: true

require "spec_helper"
require "timeout"

# A seller can lift a buyer opt-out from Customers: turning contact back on, or moving the last opted-out
# purchase to another address (its can_contact stays false, but the old address loses its veto). Either
# has to be ordered against retiring the old Gumroad newsletter, which counted that buyer as resolved.
describe PurchasesController, "seller changes while the old Gumroad newsletter retires" do
  self.use_transactional_tests = false

  let(:migration) { Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements }

  before do
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    @newsletter = create(:user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) }
    @buyer = create(:user, email: "seller-change-buyer@example.com")
    @follow = create(:follower, user: @newsletter, email: @buyer.email, follower_user_id: @buyer.id, source: Follower::From::EMBED_FORM,
                                confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    @purchase = create(:purchase, link: create(:product, user: @newsletter), email: @buyer.email, can_contact: false)
    @other_seller = create(:user)
    @other_purchase = create(:purchase, link: create(:product, user: @other_seller), email: @buyer.email, can_contact: false)
    migration.prepare!(cutoff_at: 1.hour.ago)
    migration.apply!(confirmed_eligible_count: 0) # the only follow is a buyer who opted out
    # Last changed long before retire! starts, so only the seller's change itself can put it in the recheck.
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

  def opted_out?(seller) = Purchase.where(seller_id: seller.id, email: @buyer.email, can_contact: false).exists?

  def in_thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  # Without the lock under test, the helper times out waiting; joining it must not hide the assertion that failed.
  def finish(thread)
    thread&.join(10)
  rescue Timeout::Error, StandardError
    nil
  end

  # information_schema.innodb_trx is refreshed at most every 0.1s, so poll slower than that.
  def wait_for_lock_wait(connection)
    Timeout.timeout(10) do
      sleep 0.25 until connection.uncached { connection.select_value("SELECT COUNT(*) FROM information_schema.innodb_trx WHERE trx_state = 'LOCK WAIT'") }.to_i > 0
    end
  end

  def as_seller(seller)
    sign_out :user
    sign_in seller
    yield
  end

  changes = {
    "turning contact back on" => ->(purchase) { post :change_can_contact, params: { id: purchase.external_id, can_contact: true } },
    "moving the last opted-out purchase to another address" => ->(purchase) { put :update, params: { id: purchase.external_id, email: "moved-#{purchase.id}@example.com" } },
  }

  changes.each do |name, change|
    it "refuses retirement when #{name} commits while retire!'s scan runs" do
      scanned = Queue.new
      changed = Queue.new
      allow_any_instance_of(migration).to receive(:outcome_counts).and_wrap_original do |original, *args|
        original.call(*args).tap do
          next unless args.last == Follower.all

          scanned << true
          Timeout.timeout(10) { changed.pop }
        end
      end
      retirement = in_thread { migration.retire! }
      Timeout.timeout(10) { scanned.pop }

      as_seller(@newsletter) { instance_exec(@purchase, &change) }
      changed << true

      expect(response).to have_http_status(:success)
      expect(opted_out?(@newsletter)).to be(false)
      expect { retirement.value }.to raise_error(migration::CoverageIncomplete)
      expect(cutover.state).to eq("migrated")
      expect(cutover.retirement_coverage["changed_during_scan"]).to include("eligible" => 1)
    ensure
      finish(retirement)
    end

    it "makes #{name} wait for retire! holding the cutover row; it then completes without reviving the newsletter" do
      holding = Queue.new
      allow_any_instance_of(migration).to receive(:retirement_coverage).and_wrap_original do |original, *args|
        holding << true
        wait_for_lock_wait(ActiveRecord::Base.connection)
        original.call(*args)
      end
      retirement = in_thread { migration.retire! }
      Timeout.timeout(10) { holding.pop }

      as_seller(@other_seller) { instance_exec(@other_purchase, &change) } # another creator takes no newsletter lock
      expect(opted_out?(@other_seller)).to be(false)
      expect(retirement).to be_alive
      as_seller(@newsletter) { instance_exec(@purchase, &change) }

      expect(response).to have_http_status(:success)
      retirement.value
      expect(cutover.state).to eq("retired")
      expect(opted_out?(@newsletter)).to be(false)
      expect(FeatureAnnouncementSubscription.where(user_id: @buyer.id)).to be_empty
    ensure
      finish(retirement)
    end
  end
end
