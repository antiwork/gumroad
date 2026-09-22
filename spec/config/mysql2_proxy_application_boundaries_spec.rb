# frozen_string_literal: true

require "spec_helper"

describe "mysql2 proxy application boundaries" do
  include_context "real mysql2 proxy pools"

  before do
    primary_setup do
      create(:merchant_account, user: nil) unless MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      create(:merchant_account_paypal, user: nil) unless MerchantAccount.gumroad(PaypalChargeProcessor.charge_processor_id)
    end
  end

  def dispute_event(type, capture_id, dispute_id, outcome: nil)
    {
      "event_type" => type,
      "resource" => {
        "dispute_id" => dispute_id, "create_time" => Time.current.iso8601,
        "reason" => "MERCHANDISE_OR_SERVICE_NOT_RECEIVED",
        "disputed_transactions" => [{ "seller_transaction_id" => capture_id }],
        "dispute_outcome" => { "outcome_code" => outcome }
      }
    }
  end

  def refund_event(purchase, refund_id)
    {
      "event_type" => "PAYMENT.CAPTURE.REFUNDED",
      "resource" => {
        "id" => refund_id, "amount" => { "currency_code" => "USD", "value" => "1.00" },
        "links" => [{ "href" => "https://api.sandbox.paypal.com/v2/payments/captures/#{purchase.stripe_transaction_id}" }]
      }
    }
  end

  def expect_primary_reads(reads, *tables)
    tables.each do |table|
      relevant = reads.select { |sql, _| sql.include?("`#{table}`") }
      expect(relevant).not_to be_empty
      expect(relevant.map(&:last).uniq).to eq(["primary"])
    end
  end

  it "resolves the fresh canonical charge directly even when the replica has an older purchase" do
    purchase, charge = primary_setup do
      purchase = create(:purchase, stripe_transaction_id: "routing-direct-charge")
      [purchase, create(:charge, processor_transaction_id: purchase.stripe_transaction_id, purchases: [purchase])]
    end
    replicate_record(purchase)
    event = build(:charge_event_refund_failed, charge_reference: nil, charge_id: charge.processor_transaction_id)
    expect(serving_pool).to eq("replica")
    reads = record_serving_reads { expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(charge) }
    expect_primary_reads(reads, "charges")
    expect(serving_pool).to eq("replica")
  end

  it "resolves a primary-only payment intent and purchase directly inside a reading scope" do
    purchase = primary_setup do
      create(:purchase).tap { _1.create_processor_payment_intent!(intent_id: "pi_routing_direct") }
    end
    event = build(:charge_event_refund_failed, charge_reference: nil, charge_id: nil, processor_payment_intent_id: "pi_routing_direct")
    ApplicationRecord.connected_to(role: :reading) do
      reads = record_serving_reads { expect(Charge::Chargeable.find_by_stripe_event(event)).to eq(purchase) }
      expect_primary_reads(reads, "processor_payment_intents", "purchases")
      expect(serving_pool).to eq("replica")
      expect(ApplicationRecord.current_preventing_writes).to be(true)
    end
  end

  it "creates, redelivers and resolves a synthetic PayPal charge dispute through fresh dependent purchases" do
    charge, purchases = primary_setup do
      seller = create(:user)
      account = create(:merchant_account_paypal, user: seller)
      charge = create(:charge, seller:, merchant_account: account, processor: PaypalChargeProcessor.charge_processor_id,
                               processor_transaction_id: "routing-dispute-capture", amount_cents: 2000)
      purchases = 2.times.map do
        create(:purchase_with_balance, seller:, link: create(:product, user: seller, price_cents: 1000),
                                       merchant_account: account, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                       stripe_transaction_id: charge.processor_transaction_id)
      end
      charge.purchases << purchases
      [charge, purchases]
    end
    replicate_record(charge)
    event = dispute_event("CUSTOMER.DISPUTE.CREATED", charge.processor_transaction_id, "routing-dispute")
    reads = record_serving_reads { PaypalChargeProcessor.handle_order_events(event) }
    expect_primary_reads(reads, "charges", "purchases", "disputes")
    primary_setup do
      expect(charge.reload.dispute).to be_formalized
      expect(purchases.map { _1.reload.chargeback_date }).to all(be_present)
    end
    balance_count = primary_setup { BalanceTransaction.count }
    2.times do
      cold_write_context
      PaypalChargeProcessor.handle_order_events(event)
    end
    primary_setup do
      expect(Dispute.where(charge:).count).to eq(1)
      expect(BalanceTransaction.count).to eq(balance_count)
    end
    resolved = dispute_event("CUSTOMER.DISPUTE.RESOLVED", charge.processor_transaction_id, "routing-dispute", outcome: "RESOLVED_SELLER_FAVOUR")
    reads = record_serving_reads { PaypalChargeProcessor.handle_order_events(resolved) }
    expect_primary_reads(reads, "charges", "purchases", "disputes")
    primary_setup do
      expect(charge.reload.dispute).to be_won
      expect(purchases.map { _1.reload.chargeback_reversed }).to eq([true, true])
    end
  end

  it "updates a primary-only capture fee after the write window expires" do
    purchase = primary_setup { create(:purchase, stripe_transaction_id: "routing-fee", processor_fee_cents: nil) }
    travel 3.seconds
    reads = record_serving_reads do
      PaypalChargeProcessor.handle_order_events(
        "event_type" => "PAYMENT.CAPTURE.COMPLETED",
        "resource" => { "id" => purchase.stripe_transaction_id, "seller_receivable_breakdown" => { "paypal_fee" => { "value" => "1.15", "currency_code" => "USD" } } }
      )
    end
    expect_primary_reads(reads, "purchases")
    primary_setup { expect(purchase.reload.processor_fee_cents).to eq(115) }
  end

  it "finds primary-only refund duplicates before interpreting the payload" do
    refund = primary_setup { create(:refund, processor_refund_id: "routing-duplicate") }
    reads = record_serving_reads do
      PaypalChargeProcessor.handle_order_events("event_type" => "PAYMENT.CAPTURE.REFUNDED", "resource" => { "id" => refund.processor_refund_id })
    end
    expect_primary_reads(reads, "refunds")
  end

  it "records a synthetic PayPal refund once across cold duplicate deliveries" do
    purchase = primary_setup do
      create(:purchase_with_balance, stripe_transaction_id: "routing-refund-capture", charge_processor_id: PaypalChargeProcessor.charge_processor_id)
    end
    event = refund_event(purchase, "routing-refund")
    reads = record_serving_reads { PaypalChargeProcessor.handle_order_events(event) }
    expect_primary_reads(reads, "purchases", "refunds")
    primary_setup do
      expect(purchase.refunds.where(processor_refund_id: "routing-refund").pluck(:amount_cents)).to eq([100])
    end
    PaypalChargeProcessor.handle_order_events(event)
    primary_setup { expect(purchase.refunds.where(processor_refund_id: "routing-refund").count).to eq(1) }
  end

  it "sees primary-only capture and order siblings before attributing a refund" do
    purchase, sibling = primary_setup do
      purchase = create(:purchase, stripe_transaction_id: "routing-shared", paypal_order_id: "routing-order")
      sibling = create(:purchase, purchase_state: "failed", stripe_transaction_id: nil, paypal_order_id: purchase.paypal_order_id)
      [purchase, sibling]
    end
    expect(ErrorNotifier).to receive(:notify).with(/capture is shared/, hash_including(sibling_purchase_ids: [sibling.id]))
    reads = record_serving_reads { PaypalChargeProcessor.handle_order_events(refund_event(purchase, "routing-shared-refund")) }
    expect_primary_reads(reads, "refunds", "purchases")
    sibling_reads = reads.select { |sql, _| sql.include?("`purchases`.`id` !=") }
    expect(sibling_reads.size).to eq(2)
    primary_setup { expect(purchase.reload.stripe_refunded).to be_falsey }
  end

  it "renders a delayed invitation using the fresh invitation and seller" do
    invitation = primary_setup { create(:team_invitation, email: "routing-invite@example.com") }
    message = nil
    reads = record_serving_reads { message = TeamMailer.invite(invitation).message }
    expect_primary_reads(reads, "team_invitations", "users")
    expect(message.to).to eq([invitation.email])
    expect(message.subject).to eq("Gumroad team invitation")
  end

  it "renders the refund note and seller from the primary through the merged mailer wrapper" do
    refund = primary_setup { create(:refund, note: "Synthetic routing refund", purchase: create(:purchase)) }
    replicate_record(primary_setup { refund.purchase.link })
    message = nil
    reads = record_serving_reads { message = ContactingCreatorMailer.purchase_refunded(refund.purchase_id, refund.id).message }
    expect_primary_reads(reads, "purchases", "refunds", "users")
    expect(message.body.encoded).to include("Synthetic routing refund")
  end

  it "reloads financial balance state before deciding an already applied transaction is complete" do
    transaction = primary_setup { create(:purchase_with_balance).balance_transactions.first }
    expect(transaction).to be_present
    reads = record_serving_reads { transaction.update_balance! }
    expect_primary_reads(reads, "balance_transactions")
  end

  it "keeps conditional discovery unpinned and explicit fanout on the replica" do
    job = SendPostBlastEmailsJob.new
    expect(job.send(:with_primary_database, false) { serving_pool }).to eq("replica")
    expect(job.send(:with_primary_database) { serving_pool }).to eq("primary")
    @primary.execute("UPDATE users SET name = name WHERE id = 0")
    expect(serving_pool).to eq("primary")
    expect(job.send(:with_replica_database) { serving_pool }).to eq("replica")
  end

  it "loads fresh affiliate workflow assignments through the existing job boundary" do
    assignment = primary_setup do
      affiliate = create(:direct_affiliate, send_posts: true)
      create(:product_affiliate, affiliate:, product: create(:product, user: affiliate.seller))
    end
    token = primary_setup { assignment.reload.workflow_schedule_token }
    expect(token).to be_present
    reads = record_serving_reads { ScheduleAffiliateWorkflowJobsJob.new.perform(token) }
    expect_primary_reads(reads, "affiliates_links", "affiliates", "links")
    primary_setup { expect(assignment.reload.workflow_schedule_token).to be_nil }
  end
end
