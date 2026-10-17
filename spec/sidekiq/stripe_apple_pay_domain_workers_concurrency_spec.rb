# frozen_string_literal: true

require "spec_helper"

# The two workers run on their own connections, so they cannot share the fixture transaction;
# cleanup is explicit.
describe DeleteStripeApplePayDomainWorker, "while the username's new holder registers the host" do
  self.use_transactional_tests = false

  let(:domain) { "reusedseller.gumroad.dev" }
  let!(:previous_holder) { create(:user) }
  let!(:new_holder) { create(:user) }

  before do
    StripeApplePayDomain.create!(user: previous_holder, domain:, stripe_id: "apwc_previous")
    allow(Rails.env).to receive(:test?).and_return(false)
  end

  after do
    user_ids = [previous_holder.id, new_holder.id]
    StripeApplePayDomain.where(domain:).delete_all
    Affiliate.where(affiliate_user_id: user_ids).delete_all
    RefundPolicy.where(seller_id: user_ids).delete_all
    SellerProfile.where(seller_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
  end

  def connection_id
    ActiveRecord::Base.connection.select_value("SELECT CONNECTION_ID()").to_i
  end

  # sys.innodb_lock_waits reads an innodb_trx snapshot InnoDB refreshes only after 0.1s unread, so
  # polling faster can keep returning the answer from before the wait began.
  def lock_wait_poll_seconds
    0.15
  end

  def waiting_on_domain_row_lock?(waiting_process_id, blocking_process_id)
    ActiveRecord::Base.connection.uncached do
      ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i.positive?
        SELECT COUNT(*) FROM sys.innodb_lock_waits
        WHERE waiting_pid = #{waiting_process_id.to_i}
          AND blocking_pid = #{blocking_process_id.to_i}
          AND locked_table = CONCAT('`', DATABASE(), '`.`stripe_apple_pay_domains`')
      SQL
    end
  end

  def on_own_connection(connection_ids, &block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        connection_ids << connection_id
        block.call
      end
    end
  end

  it "makes the takeover wait for an in-flight delete and then register the host afresh" do
    stripe_calls = Queue.new
    deleting = Queue.new
    release_delete = Queue.new
    allow(Stripe::ApplePayDomain).to receive(:delete) do |stripe_id|
      stripe_calls << [:delete, stripe_id]
      deleting << true
      release_delete.pop(timeout: 10)
      double(deleted: true)
    end
    allow(Stripe::ApplePayDomain).to receive(:create) do |domain_name:|
      stripe_calls << [:create, domain_name]
      double(id: "apwc_new_holder")
    end

    connection_ids = Queue.new
    delete_job = on_own_connection(connection_ids) { described_class.new.perform(previous_holder.id, domain) }
    delete_process_id = connection_ids.pop(timeout: 10) || raise("the delete never got a connection")
    deleting.pop(timeout: 10) || raise("the delete never reached Stripe")

    create_job = on_own_connection(connection_ids) do
      CreateStripeApplePayDomainWorker.new.perform(new_holder.id, domain)
    end
    create_process_id = connection_ids.pop(timeout: 10) || raise("the create never got a connection")
    deadline = 10.seconds.from_now
    create_waited = false
    until create_waited || !create_job.alive? || Time.current > deadline
      sleep lock_wait_poll_seconds
      create_waited = waiting_on_domain_row_lock?(create_process_id, delete_process_id)
    end
    release_delete << true
    [delete_job, create_job].each { |job| job.join(10) || raise("a worker did not finish") }
    [delete_job, create_job].each(&:value)

    aggregate_failures do
      expect(create_waited).to be(true)
      expect(Array.new(stripe_calls.size) { stripe_calls.pop }).to eq([[:delete, "apwc_previous"], [:create, domain]])
      expect(StripeApplePayDomain.where(domain:).pluck(:user_id, :stripe_id)).to eq([[new_holder.id, "apwc_new_holder"]])
    end
  ensure
    release_delete&.push(true)
    [delete_job, create_job].compact.each do |job|
      next if job.join(1)
      job.kill
      job.join
    end
  end
end
