# frozen_string_literal: true

require "spec_helper"
require "timeout"

# The copy and a buyer opt-out mirrored for the same account both write that account's Feature announcements
# preference and both lock the cutover row. They have to take those locks in the same order, or each can end up
# waiting on the other. The account's old address keeps its follow bound to the account, so the opt-out (at the
# old address) and the copy (of the follow at the current address) lock different follows.
describe Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements, "lock order against a buyer opt-out", :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class }

  before do
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    @newsletter = create(:user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) }
    @reader = create(:user, email: "lock-order-reader@example.com")
    @old_follow = create(:follower, user: @newsletter, email: "lock-order-old@example.com", follower_user_id: @reader.id,
                                    source: Follower::From::EMBED_FORM, confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    @current_follow = create(:follower, user: @newsletter, email: @reader.email, follower_user_id: @reader.id,
                                        source: Follower::From::EMBED_FORM, confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    @purchase = create(:purchase, link: create(:product, user: @newsletter), email: @old_follow.email)
  end

  after do
    user_ids = [@newsletter.id, @reader.id]
    FeatureAnnouncementNewsletterCutover.where(seller_id: @newsletter.id).delete_all
    FeatureAnnouncementSubscription.where(user_id: @reader.id).delete_all
    Follower.where(followed_id: @newsletter.id).delete_all
    Purchase.where(seller_id: @newsletter.id).delete_all
    link_ids = Link.where(user_id: @newsletter.id).ids
    Link.where(id: link_ids).delete_all
    AudienceMember.where(seller_id: @newsletter.id).delete_all # delete_all skips the callbacks that remove these
    [@reader, @newsletter].each(&:destroy!)
    delete_leftovers(user_ids:, link_ids:)
  end

  def cutover = FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id)

  def preference = FeatureAnnouncementSubscription.find_by(user_id: @reader.id)

  def in_thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  # The thread's result, or the error it raised (an InnoDB deadlock victim raises ActiveRecord::Deadlocked).
  def outcome(thread)
    thread.join(20) or raise "#{thread} did not finish"
    thread.value
    nil
  rescue StandardError => e
    e
  end

  def lock_waits = ActiveRecord::Base.connection.uncached { ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM performance_schema.data_lock_waits") }.to_i

  def wait_for_lock_wait = Timeout.timeout(10) { sleep 0.05 until lock_waits > 0 }

  # The seller turning contact off, in a transaction whose plain reads see the database from before prepare!, so it
  # finds the cutover row only through its locking read.
  def opt_out_with_old_snapshot(save:, saved: nil, commit: nil)
    snapshot = Queue.new
    thread = in_thread do
      ApplicationRecord.transaction do
        Purchase.where(id: @purchase.id).pick(:id)
        snapshot << true
        Timeout.timeout(20) { save.pop }
        Purchase.find(@purchase.id).tap { _1.can_contact = false }.save!
        saved&.push(true)
        Timeout.timeout(20) { commit.pop } if commit
      end
    end
    Timeout.timeout(10) { snapshot.pop }
    thread
  end

  def pause_copy_after_preference_insert
    inserted = Queue.new
    resume = Queue.new
    allow(FeatureAnnouncementSubscription).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do
        inserted << true
        Timeout.timeout(20) { resume.pop }
      end
    end
    [inserted, resume]
  end

  it "lets an opt-out arriving while the copy holds the account's new preference finish after it, with the opt-out last" do
    save = Queue.new
    opt_out = opt_out_with_old_snapshot(save:)
    migration.prepare!(cutoff_at: 1.hour.ago)
    inserted, resume = pause_copy_after_preference_insert
    copy = in_thread { migration.apply!(confirmed_eligible_count: cutover.eligible_count) }
    Timeout.timeout(10) { inserted.pop }

    save << true
    wait_for_lock_wait
    resume << true

    expect([outcome(copy), outcome(opt_out)]).to eq([nil, nil])
    expect(preference.attributes.slice("subscribed", "source", "version")).to eq("subscribed" => false, "source" => "newsletter_opt_out", "version" => 2)
    expect(cutover.attributes.slice("state", "migrated_count")).to eq("state" => "migrated", "migrated_count" => 1)
    expect(@purchase.reload.can_contact).to be(false)
  end

  it "lets the copy reaching the account while an opt-out holds the cutover row finish after it, keeping the opt-out untouched" do
    save = Queue.new
    saved = Queue.new
    commit = Queue.new
    opt_out = opt_out_with_old_snapshot(save:, saved:, commit:)
    migration.prepare!(cutoff_at: 1.hour.ago)
    reached = Queue.new
    go = Queue.new
    allow_any_instance_of(migration).to receive(:migrate).and_wrap_original do |original, seller, plan, follower|
      if follower.id == @current_follow.id
        reached << true
        Timeout.timeout(20) { go.pop }
      end
      original.call(seller, plan, follower)
    end
    copy = in_thread { migration.apply!(confirmed_eligible_count: cutover.eligible_count) }
    Timeout.timeout(10) { reached.pop }
    save << true
    Timeout.timeout(10) { saved.pop } # mirrored, holding the cutover row and the new opt-out, not yet committed

    go << true
    wait_for_lock_wait
    commit << true

    expect([outcome(copy), outcome(opt_out)]).to eq([nil, nil])
    expect(preference.attributes.slice("subscribed", "source", "version")).to eq("subscribed" => false, "source" => "newsletter_opt_out", "version" => 1)
    expect(cutover.attributes.slice("state", "migrated_count")).to eq("state" => "migrated", "migrated_count" => 0)
  end

  it "keeps the common mirror path, which sees the row and takes no cutover lock, from waiting in a cycle with the copy" do
    migration.prepare!(cutoff_at: 1.hour.ago)
    save = Queue.new
    opt_out = opt_out_with_old_snapshot(save:)
    inserted, resume = pause_copy_after_preference_insert
    copy = in_thread { migration.apply!(confirmed_eligible_count: cutover.eligible_count) }
    Timeout.timeout(10) { inserted.pop }

    save << true
    wait_for_lock_wait
    resume << true

    expect([outcome(copy), outcome(opt_out)]).to eq([nil, nil])
    expect(preference.attributes.slice("subscribed", "source", "version")).to eq("subscribed" => false, "source" => "newsletter_opt_out", "version" => 2)
    expect(cutover.migrated_count).to eq(1)
  end
end
