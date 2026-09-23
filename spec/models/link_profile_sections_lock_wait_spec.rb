# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Pins the product-create half of the seller_profiles lock contention: the `after_create` section
# write took the seller's profile row inside whatever transaction the caller opened, so a held row
# parked the create on MySQL's 50s `innodb_lock_wait_timeout` and rolled the caller's transaction
# back with it.
describe Link, "the profile row lock the after_create section write takes" do
  describe "with the seller_profiles row held by another connection" do
    # The holder thread has to see committed rows, so these examples cannot run inside the fixture
    # transaction. Cleanup is explicit for the same reason.
    self.use_transactional_tests = false

    let(:seller) { create(:user) }
    let!(:profile) { seller.seller_profile.tap(&:save!) }

    after do
      Price.where(link_id: Link.where(user_id: seller&.id).select(:id)).delete_all
      SellerProfileSection.where(seller_id: seller&.id).delete_all
      Link.where(user_id: seller&.id).delete_all
      SellerProfile.where(seller_id: seller&.id).delete_all
      User.where(id: seller&.id).delete_all
    end

    def hold_profile_row(seller)
      locked = Queue.new
      release = Queue.new
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            SellerProfile.where(seller_id: seller.id).lock.pluck(:id)
            locked << true
            release.pop
          end
        end
      end
      Timeout.timeout(15) { locked.pop }
      [thread, release]
    end

    def release_holder(thread, release)
      release << true if release
      return unless thread
      return if thread.join(10)

      thread.kill
      thread.join
    end

    it "does not spend the server's lock timeout on the create, and reports the dropped section add" do
      section = create(:seller_profile_products_section, seller:, add_new_products: true)
      reported = []
      allow(ErrorNotifier).to receive(:notify) { |exception, **context| reported << [exception, context] }
      thread, release = hold_profile_row(seller)

      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      product = create(:product, user: seller)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began

      expect(product).to be_persisted
      # The bound is the thing under test: MySQL's default is 50s, and a create that waits it out is
      # the shape this prevents. Generous, so a slow box is not the failure — an unbounded wait still
      # blows past it by an order of magnitude.
      expect(elapsed).to be < 10
      # The add is what is dropped when the wait runs out, and nothing re-adds it later.
      expect(section.reload.shown_products).to be_empty

      lock_reports = reported.select { |exception, _| exception.is_a?(ActiveRecord::LockWaitTimeout) }
      expect(lock_reports.size).to eq(1)
      expect(lock_reports.first.last).to include(product_id: product.id, seller_id: seller.id, profile_sections_lock_timeout: true)
    ensure
      release_holder(thread, release)
    end
  end

  describe "the bound's blast radius" do
    let(:seller) { create(:user) }
    let!(:profile) { seller.seller_profile.tap(&:save!) }

    it "bounds the wait for the profile row only, leaving the section writes behind it at the server's default" do
      create(:seller_profile_products_section, seller:, add_new_products: true)
      previous = ActiveRecord::Base.connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout")
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql].to_s
      end

      begin
        create(:product, user: seller)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      set_indexes = statements.each_index.select { |i| statements[i].start_with?("SET SESSION innodb_lock_wait_timeout") }
      lock_taken = statements.index { |sql| sql.include?("FOR UPDATE") }
      section_write = statements.index { |sql| sql.match?(/UPDATE .?seller_profile_sections/) }

      expect(set_indexes.size).to eq(2)
      expect(lock_taken).to be_present
      expect(section_write).to be_present
      # Before the lock is taken, so the wait it starts is the bounded one.
      expect(set_indexes.first).to be < lock_taken
      expect(statements[set_indexes.first]).to eq("SET SESSION innodb_lock_wait_timeout = #{Link::PROFILE_SECTIONS_LOCK_WAIT_TIMEOUT_SECONDS}")
      # Lifted before the section writes, which are not the wait this bound was chosen for.
      expect(set_indexes.last).to be < section_write
      expect(statements[set_indexes.last]).to eq("SET SESSION innodb_lock_wait_timeout = #{previous}")
    end

    it "restores the session's lock wait timeout, so the pooled connection hands it to no one else" do
      previous = ActiveRecord::Base.connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout")

      create(:product, user: seller)

      expect(ActiveRecord::Base.connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout")).to eq(previous)
    end
  end
end
