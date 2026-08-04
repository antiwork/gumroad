# frozen_string_literal: true

require "spec_helper"

# Each thread needs its own committed transaction and connection for the race to be real.
describe Commission, "#create_completion_purchase! concurrency", :vcr do
  self.use_transactional_tests = false

  def attach_commission_file(commission)
    commission.files.attach(file_fixture("test.pdf"))
  end

  before do
    @commission = create(:commission, status: Commission::STATUS_IN_PROGRESS)
    attach_commission_file(@commission)
  end

  after do
    purchase_ids = [@commission.deposit_purchase_id, @commission.reload.completion_purchase_id].compact
    Commission.where(id: @commission.id).delete_all
    Purchase.where(id: purchase_ids).delete_all
  end

  it "charges the buyer only once when two complete requests race" do
    entered_charge = Queue.new
    release_charge = Queue.new
    errors = Queue.new
    completion_purchase_ids = Queue.new

    # `charge!` is the network call to Stripe, invoked from `process!` inside the whole-method
    # row lock. Blocking the first thread here while the second thread calls
    # `create_completion_purchase!` reproduces the race window: without `with_lock`, both threads
    # read `completion_purchase` as absent and each build + charge their own purchase before
    # either commits one; with the lock, the second thread blocks on the DB row lock until the
    # first releases it, then finds `completion_purchase` already set and returns early.
    # Settlement bookkeeping (`update_balance_and_mark_successful!`) is out of scope for this race
    # and needs real Stripe flow-of-funds data, so leave the purchase
    # `pending_buyer_presentment_settlement?` instead.
    call_count = 0
    allow_any_instance_of(Purchase).to receive(:charge!) do |purchase|
      call_count += 1
      if call_count == 1
        entered_charge << true
        release_charge.pop
      end
      purchase.update_columns(purchase_state: "successful")
    end
    allow_any_instance_of(Purchase).to receive(:pending_buyer_presentment_settlement?).and_return(true)

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Commission.find(@commission.id).create_completion_purchase!
          completion_purchase_ids << Commission.find(@commission.id).completion_purchase_id
        rescue StandardError => e
          errors << e
        end
      end
    end

    entered_charge.pop
    sleep 0.1
    release_charge << true
    threads.each { |t| expect(t.join(10)).to eq(t) }
    raise errors.pop unless errors.empty?

    ids = Array.new(2) { completion_purchase_ids.pop }.compact.uniq
    expect(ids.size).to eq(1)
    expect(call_count).to eq(1)
  end
end
