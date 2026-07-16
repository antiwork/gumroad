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

  # A seller debit for an arbitrary refund, pinned to a specific balance —
  # for cross-balance pointer scenarios.
  def record_seller_debit!(refund:, balance:, cents:)
    issued_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -cents, net_cents: -cents)
    holding_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -cents, net_cents: -cents)
    debit = BalanceTransaction.create!(
      user: seller,
      merchant_account: purchase.merchant_account,
      refund:,
      issued_amount:,
      holding_amount:,
      update_user_balance: false
    )
    debit.update!(balance:)
    debit
  end

  describe "#perform" do
    before do
      record_refund_side_effects!
      NotifyFailedRefundExceptionJob.jobs.clear
    end

    it "marks the refund failed" do
      described_class.new(refund:).perform

      expect(refund.reload.status).to eq("failed")
    end

    it "persists Stripe's canceled status while reversing exactly the same way" do
      # Stripe delivers a canceled refund only as refund.updated with
      # status=canceled (no refund.canceled event type). It is just as terminal as
      # failed — the buyer never got the money — so the seller debit must be
      # unwound exactly once and the refund must stop counting as effective, while
      # the record keeps Stripe's actual status.
      original = refund.balance_transactions.first
      balance_before = original.balance.reload.amount_cents

      expect { described_class.new(refund:, failure_status: "canceled").perform }
        .to change(FailedRefundException, :count).by(1)

      expect(refund.reload.status).to eq("canceled")
      expect(refund.effective?).to eq(false)
      expect(Refund.effective).not_to include(refund)
      expect(refund.balance_transactions.where("issued_amount_gross_cents > 0").count).to eq(1)
      expect(original.balance.reload.amount_cents).to eq(balance_before + 1800)
      expect(purchase.reload.stripe_refunded?).to eq(false)
      expect(purchase.amount_refundable_cents).to eq(2000)

      # Re-delivery must not reverse a second time.
      expect(described_class.new(refund: Refund.find(refund.id), failure_status: "canceled").perform).to eq(false)
      expect(refund.reload.balance_transactions.where("issued_amount_gross_cents > 0").count).to eq(1)
    end

    it "coerces an unexpected failure_status to failed" do
      described_class.new(refund:, failure_status: "pending").perform

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

    it "credits a live balance when the debited balance was already paid out, leaving the paid balance untouched" do
      # A balance that was paid out is settled history: its rows must never change
      # after the payout. The offset therefore lands in an unpaid balance instead —
      # the seller is made whole either way, and payout records stay immutable.
      # (Paid-out state does not affect auto-reversal eligibility at all.)
      original = refund.balance_transactions.first
      paid_balance = original.balance
      paid_balance.update_column(:state, "paid")
      paid_amount_before = paid_balance.reload.amount_cents

      described_class.new(refund:).perform

      offset = refund.reload.balance_transactions.where("issued_amount_gross_cents > 0").first
      expect(offset.balance_id).not_to eq(paid_balance.id)
      expect(offset.balance.state).to eq("unpaid")
      expect(offset.balance.amount_cents).to be >= 1800
      expect(paid_balance.reload.amount_cents).to eq(paid_amount_before)
    end

    it "re-increments the co-purchase recommendation counts the refund decremented" do
      UpdateSalesRelatedProductsInfosJob.jobs.clear

      described_class.new(refund:).perform

      expect(UpdateSalesRelatedProductsInfosJob).to have_enqueued_sidekiq_job(purchase.id, true)
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

    it "keeps the purchase_refund_balance pointer when the surviving effective refund debited the same balance" do
      balance = refund.balance_transactions.first.balance
      surviving_refund = create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, status: "succeeded")
      record_seller_debit!(refund: surviving_refund, balance:, cents: 500)
      purchase.update!(purchase_refund_balance: balance)

      described_class.new(refund:).perform

      expect(purchase.reload.purchase_refund_balance).to eq(balance)
    end

    it "repoints purchase_refund_balance at the surviving refund's balance when the refunds debited different balances" do
      # Regression: partial refund A debits balance A, a balance transition happens,
      # partial refund B debits balance B and overwrites purchase_refund_balance
      # (decrement_balance_for_refund_or_chargeback! always points at the latest
      # refund's balance). When B then fails while A survives, keeping the pointer
      # would leave it at balance B — per-balance refund stats (User::Stats) and
      # payout exports would attribute the surviving refund A to the wrong balance.
      surviving_refund = create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, status: "succeeded")
      balance_a = create(:balance, user: seller, merchant_account: purchase.merchant_account, date: 3.days.ago.to_date)
      record_seller_debit!(refund: surviving_refund, balance: balance_a, cents: 500)
      balance_b = refund.balance_transactions.first.balance
      expect(balance_a).not_to eq(balance_b)
      purchase.update!(purchase_refund_balance: balance_b)

      described_class.new(refund:).perform

      expect(purchase.reload.purchase_refund_balance_id).to eq(balance_a.id)
      # Per-balance refunded-sales attribution follows the pointer: the purchase now
      # counts against the surviving refund's balance, not the failed one's.
      expect(Purchase.where(purchase_refund_balance_id: balance_a.id)).to include(purchase)
      expect(Purchase.where(purchase_refund_balance_id: balance_b.id)).not_to include(purchase)
    end

    it "clears purchase_refund_balance when the surviving refund left no seller debit to point at" do
      # A surviving refund without a seller balance debit (e.g. it was recorded
      # before balance transactions existed) leaves nothing to repoint at; the
      # pointer must not stay on the FAILED refund's balance.
      create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, status: "succeeded")
      purchase.update!(purchase_refund_balance: refund.balance_transactions.first.balance)

      described_class.new(refund:).perform

      expect(purchase.reload.purchase_refund_balance).to be_nil
    end

    it "restores the giftee purchase's refunded flags alongside the main purchase" do
      gift = create(:gift, gifter_purchase: purchase, link: product)
      giftee_purchase = create(:purchase, link: product, is_gift_receiver_purchase: true, stripe_refunded: true)
      gift.update!(giftee_purchase:)
      purchase.update!(is_gift_sender_purchase: true)

      described_class.new(refund:).perform

      # Both flags, not just stripe_refunded: a full-failure reversal that left the
      # giftee marked partially refunded would still revoke a gift the buyer paid for.
      giftee_purchase.reload
      expect(giftee_purchase.stripe_refunded?).to eq(false)
      expect(giftee_purchase.stripe_partially_refunded?).to eq(false)
    end

    it "restores both refunded flags on the giftee purchase after a partial-failure sequence" do
      # A surviving partial refund leaves the main purchase partially refunded; the
      # giftee mirror must land on the same pair of flags, not just have
      # stripe_refunded flipped off.
      gift = create(:gift, gifter_purchase: purchase, link: product)
      giftee_purchase = create(:purchase, link: product, is_gift_receiver_purchase: true,
                                          stripe_refunded: true, stripe_partially_refunded: false)
      gift.update!(giftee_purchase:)
      purchase.update!(is_gift_sender_purchase: true)
      create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, status: "succeeded")

      described_class.new(refund:).perform

      expect(purchase.reload.stripe_refunded?).to eq(false)
      expect(purchase.stripe_partially_refunded?).to eq(true)
      expect(giftee_purchase.reload.stripe_refunded?).to eq(false)
      expect(giftee_purchase.stripe_partially_refunded?).to eq(true)
    end

    it "restores both refunded flags on bundle product purchases after full and partial failure sequences" do
      # A refund of a bundle purchase marks each product purchase as refunded (see
      # mark_product_purchases_as_refunded!); the reversal must un-mark them the same
      # way, in both the full-failure (all flags off) and the surviving-partial
      # (partially-refunded pair) shapes — otherwise a buyer who was never made whole
      # keeps "refunded" product purchases with revoked access.
      purchase.update!(is_bundle_purchase: true)
      product_purchase = create(:purchase, link: product, is_bundle_product_purchase: true,
                                           stripe_refunded: true, stripe_partially_refunded: false)
      create(:bundle_product_purchase, bundle_purchase: purchase, product_purchase:)
      purchase.reload

      # Full-failure shape: the only refund fails, so every flag comes off.
      described_class.new(refund:).perform
      expect(purchase.reload.stripe_refunded?).to eq(false)
      expect(purchase.stripe_partially_refunded?).to eq(false)
      expect(product_purchase.reload.stripe_refunded?).to eq(false)
      expect(product_purchase.stripe_partially_refunded?).to eq(false)

      # Partial shape: a later effective partial refund survives a second failure,
      # so the mirrors must show partially refunded, not fully refunded.
      surviving = create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, status: "succeeded")
      failing = create(:refund, purchase:, amount_cents: 700, total_transaction_cents: 700,
                                processor_refund_id: "re_bundle_partial_fail", status: "pending")
      purchase.update!(stripe_refunded: false, stripe_partially_refunded: true)
      product_purchase.update!(stripe_refunded: false, stripe_partially_refunded: true)

      described_class.new(refund: failing).perform
      expect(purchase.reload.stripe_partially_refunded?).to eq(true)
      expect(purchase.stripe_refunded?).to eq(false)
      expect(product_purchase.reload.stripe_partially_refunded?).to eq(true)
      expect(product_purchase.stripe_refunded?).to eq(false)
      expect(surviving.reload.effective?).to be(true)
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
      it "reverses nothing for a real Stripe Connect merchant account" do
        # Real (unstubbed) state: a Stripe Connect account makes
        # charged_using_gumroad_merchant_account? false, so auto-reversal is refused
        # and the whole case goes to the durable exception queue.
        connect_account = create(:merchant_account_stripe_connect, user: seller)
        purchase.update!(merchant_account: connect_account)
        expect(purchase.charged_using_gumroad_merchant_account?).to eq(false)

        expect { described_class.new(refund:).perform }
          .to change(FailedRefundException, :count).by(1)

        expect(refund.reload.status).to eq("failed")
        expect(refund.balance_reversed_on_failure).to be_falsey
        expect(refund.balance_transactions.count).to eq(1) # only the original debit
        expect(purchase.reload.stripe_refunded?).to eq(true)
      end

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

      it "reverses nothing when Stripe holds the funds (Gumroad-managed custom account)" do
        # A merchant account with a user but not a Connect account is a Gumroad-managed
        # Stripe custom account: charged_using_gumroad_merchant_account? is true, but
        # the refund also debited the connected account outside our ledger, so an
        # automatic offset here would claim money the external account no longer has.
        stripe_held_account = create(:merchant_account, user: seller)
        expect(stripe_held_account.holder_of_funds).to eq(HolderOfFunds::STRIPE)
        purchase.update!(merchant_account: stripe_held_account)

        expect { described_class.new(refund:).perform }
          .to change(FailedRefundException, :count).by(1)

        expect(refund.reload.status).to eq("failed")
        expect(refund.balance_reversed_on_failure).to be_falsey
        expect(refund.balance_transactions.count).to eq(1) # only the original debit
        expect(purchase.reload.stripe_refunded?).to eq(true)
      end

      it "reverses nothing when the purchase has an unreversed chargeback" do
        # A live dispute means the money story is already contested; the reversal
        # would stack on top of chargeback accounting, so it goes to a human instead.
        purchase.update!(chargeback_date: Time.current)
        expect(purchase.chargedback_not_reversed?).to eq(true)

        expect { described_class.new(refund:).perform }
          .to change(FailedRefundException, :count).by(1)

        expect(refund.reload.status).to eq("failed")
        expect(refund.balance_reversed_on_failure).to be_falsey
        expect(refund.balance_transactions.count).to eq(1) # only the original debit
      end
    end

    context "when the refund retained the processor fee through a separate credit" do
      let!(:retention_credit) { Credit.create_for_refund_fee_retention!(refund:) }

      it "gives the retained fee back with an explicitly typed offset credit" do
        fee_cents = retention_credit.amount_cents.abs
        expect(fee_cents).to be > 0
        expect(refund.reload.retained_fee_cents.to_i).to eq(fee_cents)

        expect { described_class.new(refund:).perform }
          .to change { Credit.where(fee_retention_refund: refund).count }.from(1).to(2)

        reversal = Credit.where(fee_retention_refund: refund).failed_refund_fee_reversals.sole
        expect(reversal.amount_cents).to eq(fee_cents)
        expect(reversal.failed_refund).to eq(refund)
        expect(reversal.user).to eq(retention_credit.user)
        expect(reversal.merchant_account).to eq(retention_credit.merchant_account)
        expect(retention_credit.reload.failed_refund_id).to be_nil

        offset_transaction = reversal.balance_transaction
        expect(offset_transaction.issued_amount_gross_cents).to eq(fee_cents)
        expect(offset_transaction.holding_amount_gross_cents).to eq(fee_cents)
        expect(offset_transaction.balance_id).to be_present
      end

      it "does not create another offset on a re-delivered webhook" do
        described_class.new(refund:).perform

        expect { described_class.new(refund: Refund.find(refund.id)).perform }
          .not_to change { Credit.where(fee_retention_refund: refund).count }
      end

      it "leaves the retention credit alone when the money moved outside Gumroad's ledger" do
        allow_any_instance_of(Purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(false)

        expect { described_class.new(refund:).perform }
          .not_to change { Credit.where(fee_retention_refund: refund).count }
      end

      it "tells the exception reviewer the retained fee was given back" do
        described_class.new(refund:).perform
        failed_refund_exception = refund.reload.failed_refund_exception

        expect do
          NotifyFailedRefundExceptionJob.new.perform(failed_refund_exception.id)
        end.to change { ActionMailer::Base.deliveries.count }.by(1)

        body = ActionMailer::Base.deliveries.last.body.encoded
        expect(body).to include("also given back to the seller")
        expect(body).not_to include("NOT reversed")
      end
    end

    context "when the refund also debited an affiliate" do
      let(:affiliate_user) { create(:affiliate_user) }
      let(:affiliate) { create(:direct_affiliate, affiliate_user:, seller:) }
      let!(:affiliate_credit) do
        create(:affiliate_credit,
               purchase:,
               affiliate_user:,
               affiliate:,
               seller:,
               amount_cents: 300)
      end

      # Mirror what process_refund_or_chargeback_for_affiliate_credit_balance records:
      # a negative affiliate balance transaction linked to the refund, the refund-balance
      # pointer on the AffiliateCredit, and (for partial refunds) an AffiliatePartialRefund.
      # In production the partial-refund row's amount_cents and the debit's issued gross
      # come from the same refund_cents, so they always match — keep that invariant here.
      def record_affiliate_refund_side_effects!(partial: false, amount_cents: partial ? 150 : 300, fee_cents: 0)
        issued_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -amount_cents, net_cents: -amount_cents)
        holding_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -amount_cents, net_cents: -amount_cents)
        affiliate_transaction = BalanceTransaction.create!(
          user: affiliate_user,
          merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
          refund:,
          issued_amount:,
          holding_amount:
        )
        affiliate_credit.update!(affiliate_credit_refund_balance_id: affiliate_transaction.balance_id)
        if partial
          purchase.affiliate_partial_refunds.create!(
            total_credit_cents: 300,
            amount_cents:,
            fee_cents:,
            balance: affiliate_transaction.balance,
            seller:,
            affiliate:,
            affiliate_user:,
            affiliate_credit:
          )
        end
        affiliate_transaction
      end

      it "clears the refund-balance pointer so the commission counts as earned again" do
        record_affiliate_refund_side_effects!
        expect(AffiliateCredit.not_refunded_or_chargebacked.where(id: affiliate_credit.id)).to be_empty

        described_class.new(refund:).perform

        expect(affiliate_credit.reload.affiliate_credit_refund_balance_id).to be_nil
        expect(AffiliateCredit.not_refunded_or_chargebacked.where(id: affiliate_credit.id)).to be_present
      end

      it "destroys the failed refund's partial-refund row but keeps other refunds' rows" do
        affiliate_transaction = record_affiliate_refund_side_effects!(partial: true)
        surviving_row = purchase.affiliate_partial_refunds.create!(
          total_credit_cents: 300,
          amount_cents: 100,
          balance: create(:balance, user: affiliate_user, date: 1.week.ago.to_date),
          seller:,
          affiliate:,
          affiliate_user:,
          affiliate_credit:
        )

        described_class.new(refund:).perform

        remaining = purchase.affiliate_partial_refunds.reload
        expect(remaining).to contain_exactly(surviving_row)
        expect(remaining.where(balance_id: affiliate_transaction.balance_id)).to be_empty
      end

      it "removes only the failed refund's row when both refunds' debits share the same balance" do
        # The common production shape: the affiliate has ONE unpaid balance, so an
        # earlier (still effective) partial refund and the refund that later fails
        # both land their affiliate debits — and partial-refund rows — in it.
        # Balance-only matching would delete both rows here; the cleanup must key
        # on the failed debit itself and remove only its own row.
        affiliate_transaction = record_affiliate_refund_side_effects!(partial: true)
        shared_balance = affiliate_transaction.balance
        earlier_refund = create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, status: "succeeded")
        earlier_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -100, net_cents: -100)
        earlier_transaction = BalanceTransaction.create!(
          user: affiliate_user,
          merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
          refund: earlier_refund,
          issued_amount: earlier_amount,
          holding_amount: earlier_amount
        )
        earlier_transaction.update_column(:balance_id, shared_balance.id)
        surviving_row = purchase.affiliate_partial_refunds.create!(
          total_credit_cents: 300,
          amount_cents: 100,
          balance: shared_balance,
          seller:,
          affiliate:,
          affiliate_user:,
          affiliate_credit:
        )

        described_class.new(refund:).perform

        expect(purchase.affiliate_partial_refunds.reload).to contain_exactly(surviving_row)
      end

      it "removes exactly one row when the shared-balance rows have identical amounts" do
        # Two partial refunds of the same amount on the same balance produce
        # indistinguishable rows; the failed refund must take out exactly one,
        # never both.
        record_affiliate_refund_side_effects!(partial: true)
        purchase.affiliate_partial_refunds.create!(
          total_credit_cents: 300,
          amount_cents: 150,
          balance: purchase.affiliate_partial_refunds.sole.balance,
          seller:,
          affiliate:,
          affiliate_user:,
          affiliate_credit:
        )

        expect { described_class.new(refund:).perform }
          .to change { purchase.affiliate_partial_refunds.count }.from(2).to(1)
      end

      it "keeps the surviving row when equal debit amounts refunded different affiliate fees" do
        # With a 3% affiliate cut, both refunds debit the affiliate 5 cents, but
        # their refunded fee shares differ: 134/26 becomes 5/0, while 170/34
        # becomes 5/1. The older refund can fail after the newer one succeeds.
        refund.update!(amount_cents: 134, total_transaction_cents: 134, fee_cents: 26)
        affiliate_credit.update!(basis_points: 300, fee_cents: 10)
        failed_transaction = record_affiliate_refund_side_effects!(partial: true, amount_cents: 5, fee_cents: 0)

        surviving_refund = create(:refund, purchase:, amount_cents: 170, fee_cents: 34, status: "succeeded")
        surviving_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -5, net_cents: -5)
        surviving_transaction = BalanceTransaction.create!(
          user: affiliate_user,
          merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
          refund: surviving_refund,
          issued_amount: surviving_amount,
          holding_amount: surviving_amount
        )
        surviving_row = purchase.affiliate_partial_refunds.create!(
          total_credit_cents: 300,
          amount_cents: 5,
          fee_cents: 1,
          balance: surviving_transaction.balance,
          seller:,
          affiliate:,
          affiliate_user:,
          affiliate_credit:
        )
        expect(surviving_transaction.balance_id).to eq(failed_transaction.balance_id)

        described_class.new(refund:).perform

        expect(purchase.affiliate_partial_refunds.reload).to contain_exactly(surviving_row)
        expect(affiliate_credit.reload.fee_partially_refunded_cents).to eq(1)
      end

      it "re-points the pointer at an earlier effective refund's affiliate debit" do
        earlier_refund = create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, status: "succeeded")
        issued_amount = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -75, net_cents: -75)
        earlier_transaction = BalanceTransaction.create!(
          user: affiliate_user,
          merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
          refund: earlier_refund,
          issued_amount:,
          holding_amount: issued_amount,
          update_user_balance: false
        )
        # Record the failed refund's own debit FIRST (live balance selection would
        # otherwise drop it into whatever unpaid balance exists), then park the
        # earlier refund's debit in its own distinct balance so the assertion below
        # proves the pointer actually moves to the surviving refund's balance.
        record_affiliate_refund_side_effects!
        earlier_balance = create(:balance, user: affiliate_user, date: 2.weeks.ago.to_date)
        earlier_transaction.update_column(:balance_id, earlier_balance.id)
        expect(affiliate_credit.reload.affiliate_credit_refund_balance_id).not_to eq(earlier_balance.id)

        described_class.new(refund:).perform

        expect(affiliate_credit.reload.affiliate_credit_refund_balance_id).to eq(earlier_balance.id)
      end

      it "leaves affiliate state alone when the failed refund never touched the affiliate" do
        pointer_balance = create(:balance, user: affiliate_user, date: 2.weeks.ago.to_date)
        affiliate_credit.update!(affiliate_credit_refund_balance_id: pointer_balance.id)

        described_class.new(refund:).perform

        expect(affiliate_credit.reload.affiliate_credit_refund_balance_id).to eq(pointer_balance.id)
      end

      it "leaves affiliate state alone when the money moved outside Gumroad's ledger" do
        record_affiliate_refund_side_effects!(partial: true)
        allow_any_instance_of(Purchase).to receive(:charged_using_gumroad_merchant_account?).and_return(false)

        expect { described_class.new(refund:).perform }
          .not_to change { purchase.affiliate_partial_refunds.count }
        expect(affiliate_credit.reload.affiliate_credit_refund_balance_id).to be_present
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

    it "reverses and creates a missing queue record for a refund already marked failed" do
      refund.update!(status: "failed")

      expect { described_class.new(refund: Refund.find(refund.id)).perform }
        .to change(FailedRefundException, :count).by(1)

      failed_refund_exception = refund.reload.failed_refund_exception
      expect(refund.balance_reversed_on_failure).to eq(true)
      expect(refund.balance_transactions.where("issued_amount_gross_cents > 0").count).to eq(1)
      expect(purchase.reload.stripe_refunded?).to eq(false)
      expect(failed_refund_exception.balance_reversed?).to eq(true)
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

  describe "#perform with side effects created through the real refund path" do
    # The fixtures above hand-build the refund's balance transactions. This block
    # drives the ORIGINAL side effects through the real path instead —
    # Purchase#refund_and_save! → decrement_balance_for_refund_or_chargeback! →
    # fee-retention credit → affiliate debit — with only the external Stripe call
    # stubbed, so the reversal is proven against exactly the rows production
    # writes: seller and affiliate balances, the fee-retention credit pair, the
    # refund-balance pointers, purchase flags, and effective sums.
    let(:affiliate_user) { create(:affiliate_user) }
    let(:product) { create(:product, price_cents: 10_00) }
    let(:seller) { product.user }
    let(:affiliate) { create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1000, products: [product]) }
    let(:purchase) { create(:purchase_in_progress, link: product, seller:, affiliate:, chargeable: create(:chargeable)) }

    def stub_processor_refund!(purchase, amount_cents: nil)
      refunded_cents = amount_cents || purchase.total_transaction_cents
      stripe_refund = double("stripe_refund", status: "pending", id: "pyr_real_path_#{SecureRandom.hex(6)}")
      charge_refund = ChargeRefund.new
      charge_refund.charge_processor_id = StripeChargeProcessor.charge_processor_id
      charge_refund.id = stripe_refund.id
      charge_refund.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -refunded_cents)
      charge_refund.instance_variable_set(:@refund, stripe_refund)
      expect(ChargeProcessor).to receive(:refund!).and_return(charge_refund)
      charge_refund
    end

    before do
      purchase.process!
      purchase.update_balance_and_mark_successful!
      NotifyFailedRefundExceptionJob.jobs.clear
    end

    it "restores every real-path side effect after a full refund fails: balances, fee credit, affiliate state, flags, sums", :vcr do
      admin = create(:admin_user)
      seller_balance_before = seller.reload.unpaid_balance_cents
      affiliate_balance_before = affiliate_user.reload.unpaid_balance_cents

      stub_processor_refund!(purchase)
      expect(purchase.refund_and_save!(admin.id, reason: "buyer requested")).to be(true)
      purchase.reload
      refund = purchase.refunds.sole
      expect(purchase.stripe_refunded?).to be(true)
      expect(purchase.purchase_refund_balance_id).to be_present
      expect(purchase.affiliate_credit.affiliate_credit_refund_balance_id).to be_present
      retention_credit = Credit.where(fee_retention_refund: refund).sole
      expect(retention_credit.amount_cents).to be < 0
      expect(seller.reload.unpaid_balance_cents).to be < seller_balance_before
      expect(affiliate_user.reload.unpaid_balance_cents).to be < affiliate_balance_before

      described_class.new(refund:).perform
      purchase.reload
      refund.reload

      # Money: seller and affiliate balances return to their pre-refund values,
      # including the retained processor fee given back as an explicit credit pair.
      expect(seller.reload.unpaid_balance_cents).to eq(seller_balance_before)
      expect(affiliate_user.reload.unpaid_balance_cents).to eq(affiliate_balance_before)
      expect(Credit.where(fee_retention_refund: refund).count).to eq(2)
      expect(Credit.where(fee_retention_refund: refund).sum(:amount_cents)).to eq(0)

      # State: flags, pointers, and effective sums all treat the refund as never landed.
      expect(refund.status).to eq("failed")
      expect(refund.balance_reversed_on_failure).to eq(true)
      expect(purchase.stripe_refunded?).to eq(false)
      expect(purchase.stripe_partially_refunded?).to eq(false)
      expect(purchase.purchase_refund_balance_id).to be_nil
      expect(purchase.affiliate_credit.reload.affiliate_credit_refund_balance_id).to be_nil
      expect(purchase.amount_refundable_cents).to eq(purchase.price_cents)
      expect(purchase.amount_refunded_cents).to eq(0)
      expect(purchase.seller_balance_update_eligible?).to eq(true)
    end

    it "restores partial-refund side effects and keeps the surviving refund's attribution", :vcr do
      admin = create(:admin_user)
      seller.reload.unpaid_balance_cents

      # First partial refund succeeds and survives.
      stub_processor_refund!(purchase, amount_cents: 300)
      expect(purchase.refund_and_save!(admin.id, amount_cents: 300, reason: "partial one")).to be(true)
      purchase.reload
      surviving_refund = purchase.refunds.order(:id).last
      surviving_refund.update!(status: "succeeded")
      seller_balance_after_first = seller.reload.unpaid_balance_cents
      surviving_pointer = purchase.purchase_refund_balance_id
      expect(surviving_pointer).to be_present

      # Second partial refund is accepted, then fails.
      stub_processor_refund!(purchase, amount_cents: 400)
      expect(purchase.refund_and_save!(admin.id, amount_cents: 400, reason: "partial two")).to be(true)
      purchase.reload
      failing_refund = purchase.refunds.order(:id).last
      expect(failing_refund.id).not_to eq(surviving_refund.id)

      described_class.new(refund: failing_refund).perform
      purchase.reload

      # The surviving refund's money stays refunded; the failed one's comes back.
      expect(seller.reload.unpaid_balance_cents).to eq(seller_balance_after_first)
      expect(purchase.stripe_partially_refunded?).to eq(true)
      expect(purchase.stripe_refunded?).to eq(false)
      expect(purchase.amount_refunded_cents).to eq(300)
      # The pointer names the surviving refund's own seller-debit balance.
      surviving_debit_balance = surviving_refund.balance_transactions
                                                .where(user: seller)
                                                .where("issued_amount_gross_cents < 0")
                                                .sole.balance_id
      expect(purchase.purchase_refund_balance_id).to eq(surviving_debit_balance)
      expect(Credit.where(fee_retention_refund: failing_refund).sum(:amount_cents)).to eq(0)
      expect(Credit.where(fee_retention_refund: surviving_refund).count).to eq(1)
    end
  end
end
