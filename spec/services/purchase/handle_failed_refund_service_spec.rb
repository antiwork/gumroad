# frozen_string_literal: true

require "spec_helper"

describe Purchase::HandleFailedRefundService do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 2000) }

  let(:purchase) do
    create(:purchase_with_balance,
           link: product,
           seller:,
           price_cents: 2000,
           total_transaction_cents: 2000)
  end

  let(:refund) do
    create(:refund,
           purchase:,
           amount_cents: 2000,
           total_transaction_cents: 2000,
           processor_refund_id: "re_failed_test",
           status: "pending")
  end

  # Mirror what refund_purchase! records: a negative (debit) balance transaction
  # linked to the refund, and the purchase marked refunded.
  def record_refund_side_effects!
    issued_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -2000, net_cents: -1800)
    holding_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -2000, net_cents: -1800)
    BalanceTransaction.create!(
      user: seller,
      merchant_account: purchase.merchant_account,
      refund:,
      issued_amount:,
      holding_amount:
    )
    purchase.update!(stripe_refunded: true, stripe_partially_refunded: false)
  end

  before do
    record_refund_side_effects!
    NotifyFailedRefundExceptionJob.jobs.clear
  end

  describe "#perform" do
    it "marks the refund failed" do
      described_class.new(refund:).perform

      expect(refund.reload.status).to eq("failed")
    end

    it "offsets every balance transaction the refund created with an equal-and-opposite one" do
      original = refund.balance_transactions.first
      balance_before = original.balance.reload.amount_cents

      described_class.new(refund:).perform

      reversals = refund.reload.balance_transactions.where.not(id: original.id)
      expect(reversals.count).to eq(1)
      reversal = reversals.first
      expect(reversal.issued_amount_gross_cents).to eq(2000)
      expect(reversal.issued_amount_net_cents).to eq(1800)
      expect(reversal.holding_amount_gross_cents).to eq(2000)
      expect(reversal.holding_amount_net_cents).to eq(1800)
      expect(reversal.issued_amount_currency).to eq(original.issued_amount_currency)
      expect(original.balance.reload.amount_cents).to eq(balance_before + 1800)
    end

    it "un-marks the purchase as refunded so it can be re-refunded" do
      expect { described_class.new(refund:).perform }
        .to change { purchase.reload.stripe_refunded? }.from(true).to(false)
      expect(purchase.stripe_partially_refunded?).to eq(false)
    end

    it "restores the refundable amount so the purchase can actually be re-refunded" do
      # Regression: preview QA (PR #5779) found that although the refunded flags were
      # reset, refunds.sum(:amount_cents) still counted the failed row, leaving
      # amount_refundable_cents at 0 and refund_and_save! silently returning false.
      # Failed refunds must not count as refunded money anywhere.
      expect { described_class.new(refund:).perform }
        .to change { purchase.reload.amount_refundable_cents }.from(0).to(2000)
      expect(purchase.amount_refunded_cents).to eq(0)
      expect(purchase.gross_amount_refunded_cents).to eq(0)
    end

    it "clears the purchase_refund_balance pointer so a re-refund debits the seller again" do
      # Regression: the original refund parks the seller's debited balance in
      # purchase_refund_balance, and seller_balance_update_eligible? refuses a second
      # debit while it's set (for a fully-refunded purchase). Without clearing it, a
      # re-refund after a failure would move real money at Stripe but never debit the
      # seller — the seller keeps earnings for a sale the buyer got refunded.
      purchase.update!(purchase_refund_balance: refund.balance_transactions.first.balance)

      described_class.new(refund:).perform

      expect(purchase.reload.purchase_refund_balance).to be_nil
      expect(purchase.seller_balance_update_eligible?).to eq(true)
    end

    it "keeps the purchase_refund_balance pointer when another effective refund remains" do
      create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, status: "succeeded")
      balance = refund.balance_transactions.first.balance
      purchase.update!(purchase_refund_balance: balance)

      described_class.new(refund:).perform

      expect(purchase.reload.purchase_refund_balance).to eq(balance)
    end

    it "restores the giftee purchase's refunded flags alongside the main purchase" do
      gift = create(:gift, gifter_purchase: purchase, link: product)
      giftee_purchase = create(:purchase, link: product, is_gift_receiver_purchase: true, stripe_refunded: true)
      gift.update!(giftee_purchase:)
      purchase.update!(is_gift_sender_purchase: true)

      described_class.new(refund:).perform

      expect(giftee_purchase.reload.stripe_refunded?).to eq(false)
    end

    it "mirrors update_user_balance from the original transaction" do
      # An original debit created with update_user_balance: false (e.g. an affiliate
      # debit during a merchant migration) has no balance attached; its offset must
      # not credit a live balance the original never debited.
      issued_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -100, net_cents: -100)
      holding_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -100, net_cents: -100)
      no_balance_original = BalanceTransaction.create!(
        user: seller,
        merchant_account: purchase.merchant_account,
        refund:,
        issued_amount:,
        holding_amount:,
        update_user_balance: false
      )
      expect(no_balance_original.balance_id).to be_nil

      described_class.new(refund:).perform

      offsets = refund.reload.balance_transactions.where("issued_amount_gross_cents > 0")
      no_balance_offset = offsets.find { |bt| bt.issued_amount_gross_cents == 100 }
      expect(no_balance_offset.balance_id).to be_nil
      with_balance_offset = offsets.find { |bt| bt.issued_amount_gross_cents == 2000 }
      expect(with_balance_offset.balance_id).to be_present
    end

    context "when the refund's money moved outside Gumroad's ledger" do
      it "marks the refund failed but reverses nothing for a Stripe Connect purchase" do
        allow_any_instance_of(Purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(false)

        expect { described_class.new(refund:).perform }
          .to change(FailedRefundException, :count).by(1)

        expect(refund.reload.status).to eq("failed")
        expect(refund.balance_reversed_on_failure).to be_falsey
        expect(refund.balance_transactions.count).to eq(1) # only the original debit
        expect(purchase.reload.stripe_refunded?).to eq(true) # untouched pending exception resolution
        failed_refund_exception = refund.failed_refund_exception
        expect(failed_refund_exception.balance_reversed?).to eq(false)
        expect(NotifyFailedRefundExceptionJob).to have_enqueued_sidekiq_job(failed_refund_exception.id)
      end

      it "re-enqueues an unsent durable exception without creating another record" do
        allow_any_instance_of(Purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(false)
        expect(described_class.new(refund:).perform).to eq(true)
        failed_refund_exception = refund.failed_refund_exception
        NotifyFailedRefundExceptionJob.jobs.clear

        expect { described_class.new(refund: Refund.find(refund.id)).perform }
          .not_to change(FailedRefundException, :count)
        expect(NotifyFailedRefundExceptionJob).to have_enqueued_sidekiq_job(failed_refund_exception.id)
      end

      it "does not enqueue a sent notification again" do
        allow_any_instance_of(Purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(false)
        expect(described_class.new(refund:).perform).to eq(true)
        refund.failed_refund_exception.update!(notification_sent_at: Time.current)
        NotifyFailedRefundExceptionJob.jobs.clear

        expect(described_class.new(refund: Refund.find(refund.id)).perform).to eq(false)
        expect(NotifyFailedRefundExceptionJob.jobs.size).to eq(0)
      end
    end

    it "keeps a partial refund flag when another non-failed refund remains" do
      create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, status: "succeeded")

      described_class.new(refund:).perform

      expect(purchase.reload.stripe_refunded?).to eq(false)
      expect(purchase.stripe_partially_refunded?).to eq(true)
    end

    it "persists the configured routing policy with the exception record" do
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get)
        .with("FAILED_REFUND_EXCEPTION_OWNER", FailedRefundException::DEFAULT_OWNER)
        .and_return("refund-operations")
      allow(GlobalConfig).to receive(:get)
        .with("FAILED_REFUND_EXCEPTION_RESPONSE_SLA_HOURS", FailedRefundException::DEFAULT_RESPONSE_SLA_HOURS)
        .and_return("48")
      allow(GlobalConfig).to receive(:get)
        .with("FAILED_REFUND_EXCEPTION_NOTIFICATION_ROOM", "refund-operations")
        .and_return("risk")

      freeze_time do
        expect { described_class.new(refund:).perform }
          .to change(FailedRefundException, :count).by(1)

        failed_refund_exception = refund.failed_refund_exception
        expect(failed_refund_exception).to have_attributes(
          owner: "refund-operations",
          notification_room: "risk",
          state: "pending",
          due_at: 48.hours.from_now,
          balance_reversed: true,
          notification_sent_at: nil
        )
        expect(NotifyFailedRefundExceptionJob).to have_enqueued_sidekiq_job(failed_refund_exception.id)
      end
    end

    it "rolls back failure handling when the configured notification room is invalid" do
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get)
        .with("FAILED_REFUND_EXCEPTION_NOTIFICATION_ROOM", FailedRefundException::DEFAULT_OWNER)
        .and_return("unknown-room")

      expect { described_class.new(refund:).perform }
        .to raise_error(ArgumentError, /Unknown failed-refund notification room/)

      expect(refund.reload).to have_attributes(status: "pending", balance_reversed_on_failure: be_falsey)
      expect(FailedRefundException.where(refund:).exists?).to eq(false)
      expect(NotifyFailedRefundExceptionJob.jobs.size).to eq(0)
    end

    it "rolls back the queue record when the reversal fails" do
      allow_any_instance_of(described_class).to receive(:reverse_balance_transactions!).and_raise("reversal failed")

      expect { described_class.new(refund:).perform }.to raise_error("reversal failed")

      expect(FailedRefundException.where(refund:).exists?).to eq(false)
      expect(refund.reload.status).to eq("pending")
      expect(NotifyFailedRefundExceptionJob.jobs.size).to eq(0)
    end

    it "creates a missing queue record for a refund already marked failed" do
      refund.update!(status: "failed")

      expect { described_class.new(refund: Refund.find(refund.id)).perform }
        .to change(FailedRefundException, :count).by(1)

      failed_refund_exception = refund.reload.failed_refund_exception
      expect(failed_refund_exception.balance_reversed?).to eq(false)
      expect(NotifyFailedRefundExceptionJob).to have_enqueued_sidekiq_job(failed_refund_exception.id)
    end

    it "is idempotent across re-delivered webhooks" do
      expect(described_class.new(refund:).perform).to eq(true)
      transactions_after_first = refund.reload.balance_transactions.count

      expect(described_class.new(refund:).perform).to eq(false)
      expect(refund.reload.balance_transactions.count).to eq(transactions_after_first)
    end

    it "is a no-op when another worker already recorded the reversal (stale in-memory guard)" do
      # Simulates two workers racing on the same refund.failed webhook: this worker's
      # in-memory refund still has balance_reversed_on_failure unset, but by the time
      # it takes the row lock the other worker has committed the reversal. The
      # post-lock re-check must catch it — otherwise the seller is credited twice.
      stale_refund = Refund.find(refund.id)
      expect(described_class.new(refund:).perform).to eq(true)
      transactions_after_first = refund.reload.balance_transactions.count

      expect(ErrorNotifier).not_to receive(:notify)
      expect(described_class.new(refund: stale_refund).perform).to eq(false)
      expect(refund.reload.balance_transactions.count).to eq(transactions_after_first)
    end

    it "counts legacy NULL-status refunds when recomputing the refunded flags" do
      # Refunds created before the status column existed have status NULL; they were
      # real, completed refunds and must still count as refunded money.
      create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, status: nil)

      described_class.new(refund:).perform

      expect(purchase.reload.stripe_refunded?).to eq(false)
      expect(purchase.stripe_partially_refunded?).to eq(true)
    end

    it "reverses presentment refunds using the recorded canonical amounts" do
      refund.presentment_currency = Currency::EUR
      refund.presentment_amount_cents = 1850
      refund.save!

      described_class.new(refund:).perform

      # The reversal mirrors the original (canonical USD) balance transaction; the
      # presentment snapshot on the refund stays untouched for reconciliation.
      reversal = refund.reload.balance_transactions.order(:id).last
      expect(reversal.issued_amount_currency).to eq(Currency::USD)
      expect(reversal.issued_amount_gross_cents).to eq(2000)
      expect(refund.presentment_amount_cents).to eq(1850)
    end

    it "allows a full end-to-end re-refund that debits the seller again" do
      # The whole point of the reversal: after the failure is handled, a support
      # re-refund must behave like a first refund — real processor call, a new
      # effective refund row, and a fresh seller balance debit. This is the exact
      # sequence preview QA exercised (refund → refund.failed → re-refund).
      purchase.update!(purchase_refund_balance: refund.balance_transactions.first.balance)
      described_class.new(refund:).perform
      purchase.reload

      stripe_refund = double("stripe_refund", status: "pending", id: "re_rerefund_#{SecureRandom.hex(6)}")
      charge_refund = ChargeRefund.new
      charge_refund.charge_processor_id = StripeChargeProcessor.charge_processor_id
      charge_refund.id = stripe_refund.id
      charge_refund.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -2000)
      charge_refund.instance_variable_set(:@refund, stripe_refund)
      expect(ChargeProcessor).to receive(:refund!)
        .with(purchase.charge_processor_id, purchase.stripe_transaction_id, hash_including(amount_cents: nil))
        .and_return(charge_refund)

      # Refund as a Gumroad team member (the admin flow exercised in preview QA);
      # creator-initiated refunds additionally check the seller's unpaid balance.
      admin = create(:admin_user)
      expect(purchase.refund_and_save!(admin.id, reason: "re-refund after bounced bank-transfer refund")).to be(true)

      purchase.reload
      expect(purchase.stripe_refunded?).to eq(true)
      new_refund = purchase.refunds.order(:id).last
      expect(new_refund.id).not_to eq(refund.id)
      expect(new_refund.amount_cents).to eq(2000)
      seller_debits = new_refund.balance_transactions.where(user: seller)
                                .where("issued_amount_gross_cents < 0")
      expect(seller_debits).to be_present
    end
  end
end
