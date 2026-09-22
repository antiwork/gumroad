# frozen_string_literal: true

require "spec_helper"

# SendChargeReceiptJob is enqueued from the checkout request as the charge commits and runs on a
# worker whose reads land on a replica. These examples run against real primary/replica pools and
# assert the connection each statement was served by, not where it sat on the connected_to stack.
describe "mysql2 proxy charge receipt routing" do
  include_context "real mysql2 proxy pools"

  before do
    primary_setup do
      create(:merchant_account, user: nil) unless MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
    end
  end

  def expect_serving_pool(reads, pool, *tables)
    tables.each do |table|
      relevant = reads.select { |sql, _| sql.include?("`#{table}`") }
      expect(relevant).not_to be_empty
      expect(relevant.map(&:last).uniq).to eq([pool])
    end
  end

  # A run that wrote leaves the proxy's recent-write window open, and that alone sends reads to the
  # primary. Drop the window: a primary read after it could only come from a pin that never unwound.
  def expect_pin_unwound
    cold_write_context
    expect(serving_pool).to eq("replica")
  end

  def create_charge(name)
    primary_setup do
      seller = create(:user)
      purchase = create(:purchase, seller:, link: create(:product, user: seller, name:))
      charge = create(:charge, seller:, purchases: [purchase])
      charge.order.purchases << purchase
      charge
    end
  end

  def send_receipt(charge)
    SendChargeReceiptJob.new.perform(charge.id)
  end

  it "sends the receipt for a charge the replica has not received yet" do
    charge = create_charge("Routing Receipt")
    expect(serving_pool).to eq("replica")

    reads = nil
    expect do
      reads = record_serving_reads { send_receipt(charge) }
    end.to change { ActionMailer::Base.deliveries.count }.by(1)

    expect_serving_pool(reads, "primary", "charges", "purchases")
    expect(ActionMailer::Base.deliveries.last.subject).to include("Routing Receipt")
    expect(primary_setup { charge.reload.receipt_sent? }).to be(true)
    expect_pin_unwound
  end

  # The silent half: unpinned, the purchases are missing, so the job returns without sending and
  # nothing re-enqueues.
  it "reads the purchases of a replicated charge from the primary" do
    charge = create_charge("Routing Lazy Purchases")
    replicate_record(charge)

    reads = nil
    expect do
      reads = record_serving_reads { send_receipt(charge) }
    end.to change { ActionMailer::Base.deliveries.count }.by(1)

    expect_serving_pool(reads, "primary", "purchases")
    expect(primary_setup { charge.reload.receipt_sent? }).to be(true)
    expect_pin_unwound
  end

  it "unwinds the pin when the job raises" do
    charge = create_charge("Routing Raise")
    pool_at_raise = nil
    allow(CustomerMailer).to receive(:receipt) do
      pool_at_raise = serving_pool
      raise ActiveRecord::Deadlocked, "routing"
    end

    expect { send_receipt(charge) }.to raise_error(ActiveRecord::Deadlocked, "routing")

    expect(pool_at_raise).to eq("primary")
    # Nothing was written before the raise, so the replica is where an unwound pin leaves this.
    expect(serving_pool).to eq("replica")
    expect(primary_setup { charge.reload.receipt_sent? }).to be(false)
  end

  it "does not resend a receipt an earlier run delivered" do
    charge = create_charge("Routing Idempotent")
    expect { send_receipt(charge) }.to change { ActionMailer::Base.deliveries.count }.by(1)

    reads = nil
    expect do
      reads = record_serving_reads { send_receipt(charge) }
    end.not_to change { ActionMailer::Base.deliveries.count }

    # The early return on receipt_sent? reads the charge from the primary and unwinds like a send.
    expect_serving_pool(reads, "primary", "charges")
    expect_pin_unwound
  end
end
