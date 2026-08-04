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

# Regression for a fable-5 finding on the with_lock fix above: a raise from ANYWHERE inside the
# locked block after a successful charge (not just the synthesized RecordInvalid on
# `pending_completion.errors`) must not roll the transaction back, or a committed Stripe charge
# is left with zero database trace and a retry double-charges the buyer.
describe Commission, "#create_completion_purchase! post-charge failure" do
  it "keeps the charged completion purchase persisted when a later step raises" do
    # Reuses the sibling "marks the purchase as failed" cassette for the credit-card tokenization
    # and successful payment_intent creation calls that the deposit factory and `process!` make —
    # this spec only needs a completion purchase to reach `successful` before the later step
    # raises, not a fresh recording.
    VCR.use_cassette("Commission/_create_completion_purchase_/when_status_is_not_completed/creates_a_completion_purchase_with_correct_attributes_processes_it_and_updates_status") do
      commission = create(:commission, status: Commission::STATUS_IN_PROGRESS)
      commission.files.attach(file_fixture("test.pdf"))

      allow_any_instance_of(Purchase).to receive(:pending_buyer_presentment_settlement?).and_return(false)
      allow_any_instance_of(Purchase).to receive(:update_balance_and_mark_successful!).and_raise(RuntimeError, "boom after charge")

      expect { commission.create_completion_purchase! }.to raise_error(RuntimeError, "boom after charge")
    end

    # `update_balance_and_mark_successful!` raising before it can flip the purchase to
    # `successful` leaves it `in_progress`, so `ensure_completion`'s own `ensure` block marks it
    # `failed` — same as the pre-existing "when the completion purchase fails" spec. The point of
    # THIS spec is that the mark-failed write, and the charged purchase row itself (with its real
    # Stripe transaction id from the cassette), survive `with_lock`'s transaction instead of being
    # rolled back with everything else the raise unwound.
    completion_purchase = Purchase.is_commission_completion_purchase.last
    expect(completion_purchase).to be_present
    expect(completion_purchase).to be_failed
    expect(completion_purchase.stripe_transaction_id).to be_present
  end
end
