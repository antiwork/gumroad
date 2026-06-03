# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillSelfAffiliateDroppedProceeds do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000) }
  let(:in_window_time) { described_class::REMEDIATION_WINDOW.first + 1.day }
  let(:merchant_account) { MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) }

  def build_affected_purchase(price_cents: 1000, affiliate_credit_cents: 79, fee_cents: 209,
                              total_transaction_cents: nil, created_at: in_window_time,
                              affiliate: seller.global_affiliate, **overrides)
    purchase = create(:purchase,
                      seller:,
                      link: product,
                      price_cents:,
                      affiliate:,
                      total_transaction_cents: total_transaction_cents || price_cents,
                      created_at:,
                      succeeded_at: created_at,
                      **overrides)
    purchase.update_columns(fee_cents:, affiliate_credit_cents:)
    create_affiliate_leg_bt(purchase.reload)
    purchase.reload
  end

  def create_affiliate_leg_bt(purchase)
    BalanceTransaction.create!(
      user: purchase.seller,
      merchant_account:,
      purchase:,
      issued_amount: BalanceTransaction::Amount.new(
        currency: Currency::USD,
        gross_cents: purchase.affiliate_credit_cents,
        net_cents: purchase.affiliate_credit_cents,
      ),
      holding_amount: BalanceTransaction::Amount.new(
        currency: Currency::USD,
        gross_cents: purchase.affiliate_credit_cents,
        net_cents: purchase.affiliate_credit_cents,
      ),
      update_user_balance: true,
    )
  end

  describe "#process (dry run, default)" do
    it "reports the affected purchase as creditable without creating a balance transaction" do
      purchase = build_affected_purchase
      expect do
        result = described_class.new.process
        expect(result[:stats][:credited]).to eq(1)
        expect(result[:credited].first[:purchase_id]).to eq(purchase.id)
        expect(result[:credited].first[:credited_cents]).to eq(purchase.payment_cents - purchase.affiliate_credit_cents.to_i)
      end.not_to(change { BalanceTransaction.count })
    end
  end

  describe "#process (live run)" do
    it "creates the missing seller-leg balance transaction with correct amounts" do
      purchase = build_affected_purchase(price_cents: 1000, fee_cents: 209, affiliate_credit_cents: 79)
      expected_net = purchase.payment_cents - purchase.affiliate_credit_cents.to_i

      expect do
        described_class.new(dry_run: false).process
      end.to change { purchase.balance_transactions.count }.from(1).to(2)

      new_bt = purchase.balance_transactions.order(:id).last
      expect(new_bt.user_id).to eq(seller.id)
      expect(new_bt.merchant_account_id).to eq(merchant_account.id)
      expect(new_bt.issued_amount_currency).to eq(Currency::USD)
      expect(new_bt.issued_amount_gross_cents).to eq(purchase.total_transaction_cents)
      expect(new_bt.issued_amount_net_cents).to eq(expected_net)
      expect(new_bt.holding_amount_currency).to eq(Currency::USD)
      expect(new_bt.holding_amount_gross_cents).to eq(purchase.total_transaction_cents)
      expect(new_bt.holding_amount_net_cents).to eq(expected_net)
    end

    it "attaches the new seller-leg BT to the same Balance as the affiliate-leg BT when it is still unpaid" do
      purchase = build_affected_purchase
      affiliate_bt = purchase.balance_transactions.first
      original_balance_id = affiliate_bt.balance_id
      expected_increment = purchase.payment_cents - purchase.affiliate_credit_cents.to_i

      expect do
        described_class.new(dry_run: false).process
      end.to change { Balance.find(original_balance_id).amount_cents }.by(expected_increment)

      new_bt = purchase.balance_transactions.order(:id).last
      expect(new_bt.balance_id).to eq(original_balance_id)
      expect(purchase.reload.purchase_success_balance_id).to eq(original_balance_id)
    end

    it "creates a fresh unpaid balance and repoints purchase_success_balance_id when the original balance has been paid out" do
      purchase = build_affected_purchase
      affiliate_bt = purchase.balance_transactions.first
      original_balance = Balance.find(affiliate_bt.balance_id)
      purchase.update_columns(purchase_success_balance_id: original_balance.id)
      original_balance.mark_processing!
      original_balance.mark_paid!

      expect do
        described_class.new(dry_run: false).process
      end.to change { purchase.balance_transactions.count }.from(1).to(2)

      new_bt = purchase.balance_transactions.order(:id).last
      expect(new_bt.balance_id).not_to eq(original_balance.id)

      new_balance = Balance.find(new_bt.balance_id)
      expect(new_balance.state).to eq("unpaid")
      expect(new_balance.user_id).to eq(seller.id)
      expect(new_balance.amount_cents).to eq(purchase.payment_cents - purchase.affiliate_credit_cents.to_i)

      expect(purchase.reload.purchase_success_balance_id).to eq(new_balance.id)
      expect(original_balance.reload.state).to eq("paid")
    end

    it "is idempotent: a second run does not credit again" do
      purchase = build_affected_purchase
      described_class.new(dry_run: false).process
      expect(purchase.balance_transactions.count).to eq(2)

      second_run = described_class.new(dry_run: false).process
      expect(second_run[:stats][:credited]).to eq(0)
      expect(second_run[:stats][:unexpected_bt_count]).to eq(1)
      expect(purchase.balance_transactions.count).to eq(2)
    end

    it "acquires Purchase.lock during eligibility + BT insert to serialize concurrent runs" do
      purchase = build_affected_purchase
      lock_relation = double("lock_relation")
      expect(Purchase).to receive(:lock).at_least(:once).and_return(lock_relation)
      expect(lock_relation).to receive(:find).with(purchase.id).at_least(:once).and_return(purchase)

      described_class.new(dry_run: false, purchase_ids: [purchase.id]).process
      expect(purchase.balance_transactions.count).to eq(2)
    end

    it "differentiates rescue messaging when update_balance! succeeded but purchase FK update failed" do
      purchase = build_affected_purchase
      allow(Purchase).to receive(:where).and_wrap_original do |orig, *args, &blk|
        rel = orig.call(*args, &blk)
        allow(rel).to receive(:update_all).and_raise(ActiveRecord::ConnectionNotEstablished, "boom")
        rel
      end

      result = described_class.new(dry_run: false, purchase_ids: [purchase.id], verbose: true).process

      expect(result[:stats][:error]).to eq(1)
      err = result[:skipped][:error].first
      expect(err[:bt_id]).to be_present
      expect(err[:balance_id]).to be_present
      expect(err[:recovery]).to include("DO NOT re-run update_balance!")
      expect(purchase.balance_transactions.count).to eq(2)
      expect(purchase.balance_transactions.order(:id).last.balance_id).to be_present
    end

    it "differentiates rescue messaging when BT was inserted but update_balance! failed" do
      purchase = build_affected_purchase
      allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_raise(StandardError, "boom")

      result = described_class.new(dry_run: false, purchase_ids: [purchase.id], verbose: true).process

      expect(result[:stats][:error]).to eq(1)
      err = result[:skipped][:error].first
      expect(err[:orphan_bt_id]).to be_present
      expect(err[:recovery]).to include("Inspect seller's Balance")
      expect(purchase.balance_transactions.count).to eq(2)
      expect(purchase.balance_transactions.order(:id).last.balance_id).to be_nil
    end

    it "calls update_balance! outside the Purchase-row lock to avoid Balance/Purchase deadlock" do
      purchase = build_affected_purchase
      transaction_open = false
      saw_balance_lock_inside_transaction = false

      allow(ApplicationRecord).to receive(:transaction).and_wrap_original do |orig, *args, &blk|
        transaction_open = true
        result = orig.call(*args, &blk)
        transaction_open = false
        result
      end

      allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_wrap_original do |orig, *args|
        saw_balance_lock_inside_transaction = true if transaction_open
        orig.call(*args)
      end

      described_class.new(dry_run: false, purchase_ids: [purchase.id]).process
      expect(saw_balance_lock_inside_transaction).to eq(false)
    end
  end

  describe "skip conditions" do
    it "skips purchases created before the remediation window" do
      build_affected_purchase(created_at: described_class::BUG_INTRODUCED_AT - 1.day)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips purchases created after the remediation window" do
      build_affected_purchase(created_at: described_class::BUG_FIXED_AT + 1.day)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips failed purchases" do
      build_affected_purchase(purchase_state: "failed")
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
    end

    it "skips zero-price purchases" do
      build_affected_purchase(price_cents: 0, affiliate_credit_cents: 0)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
    end

    it "skips refunded purchases" do
      purchase = build_affected_purchase
      purchase.update!(stripe_refunded: true)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:refunded]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips partially refunded purchases" do
      purchase = build_affected_purchase
      purchase.update!(stripe_partially_refunded: true)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:partially_refunded]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips chargedback purchases" do
      purchase = build_affected_purchase
      purchase.update!(chargeback_date: Time.current)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:chargedback]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips purchases whose affiliate is not the seller (real affiliate sale)" do
      other_affiliate_user = create(:user)
      direct_affiliate = create(:direct_affiliate, seller:, affiliate_user: other_affiliate_user)
      build_affected_purchase(affiliate: direct_affiliate)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
    end

    it "skips purchases that already have 2 balance transactions" do
      purchase = build_affected_purchase
      create_affiliate_leg_bt(purchase)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:unexpected_bt_count]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips purchases whose existing BT amount doesn't match affiliate_credit_cents" do
      purchase = build_affected_purchase
      purchase.balance_transactions.first.update_column(:issued_amount_net_cents, 999)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:bt_amount_mismatch]).to eq(1)
    end

    it "skips purchases in the manual-credit allow-list" do
      purchase = build_affected_purchase
      stub_const("#{described_class.name}::ALREADY_CREDITED_PURCHASE_IDS", [purchase.id].freeze)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
    end

    it "skips when affiliate_credit_cents is 0" do
      purchase = build_affected_purchase
      purchase.update_columns(affiliate_credit_cents: 0)
      result = described_class.new(dry_run: false, verbose: true).process
      expect(result[:stats][:no_affiliate_credit]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
      expect(result[:skipped][:no_affiliate_credit]).to eq([purchase.id])
    end

    it "skips when affiliate_credit_cents equals payment_cents (nothing to credit)" do
      build_affected_purchase(price_cents: 1000, fee_cents: 209, affiliate_credit_cents: 791)
      result = described_class.new(dry_run: false, verbose: true).process
      expect(result[:stats][:nothing_to_credit]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips when affiliate_credit_cents exceeds payment_cents (negative missing)" do
      build_affected_purchase(price_cents: 1000, fee_cents: 209, affiliate_credit_cents: 900)
      result = described_class.new(dry_run: false, verbose: true).process
      expect(result[:stats][:nothing_to_credit]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips when total_transaction_cents is 0" do
      purchase = build_affected_purchase
      purchase.update_columns(total_transaction_cents: 0)
      result = described_class.new(dry_run: false, verbose: true, purchase_ids: [purchase.id]).process
      expect(result[:stats][:invalid_total_transaction_cents]).to eq(1)
    end

    it "skips when the existing BT has a missing currency" do
      purchase = build_affected_purchase
      purchase.balance_transactions.first.update_columns(issued_amount_currency: nil)
      result = described_class.new(dry_run: false, verbose: true).process
      expect(result[:stats][:bt_currency_missing]).to eq(1)
    end

    it "skips when the existing BT belongs to a different user" do
      purchase = build_affected_purchase
      other = create(:user)
      purchase.balance_transactions.first.update_columns(user_id: other.id)
      result = described_class.new(dry_run: false, verbose: true).process
      expect(result[:stats][:bt_wrong_user]).to eq(1)
    end

    it "skips when no balance_transactions exist at all" do
      purchase = build_affected_purchase
      purchase.balance_transactions.first.destroy!
      result = described_class.new(dry_run: false, verbose: true).process
      expect(result[:stats][:unexpected_bt_count]).to eq(1)
    end

    it "skips Brazilian Stripe Connect / non-Gumroad-merchant purchases" do
      purchase = build_affected_purchase
      seller_stripe_account = create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id)
      allow_any_instance_of(MerchantAccount).to receive(:is_managed_by_gumroad?).and_return(false)
      allow_any_instance_of(MerchantAccount).to receive(:is_a_stripe_connect_account?).and_return(true)
      purchase.update_columns(merchant_account_id: seller_stripe_account.id)
      result = described_class.new(dry_run: false, verbose: true, purchase_ids: [purchase.id]).process
      expect(result[:stats][:not_gumroad_merchant]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips Bruno's allow-listed purchases even when supplied via explicit purchase_ids" do
      purchase = build_affected_purchase
      stub_const("#{described_class.name}::ALREADY_CREDITED_PURCHASE_IDS", [purchase.id].freeze)
      result = described_class.new(dry_run: false, verbose: true, purchase_ids: [purchase.id]).process
      expect(result[:stats][:already_credited]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
      expect(purchase.balance_transactions.count).to eq(1)
    end
  end

  describe "purchase variations preserved by the bug" do
    it "credits subscription / recurring purchases the same way" do
      subscription = create(:subscription, link: product, user: seller)
      purchase = build_affected_purchase
      purchase.update_columns(subscription_id: subscription.id)
      expect do
        described_class.new(dry_run: false).process
      end.to change { purchase.balance_transactions.count }.from(1).to(2)
    end

    it "credits gift-sender purchases the same way" do
      purchase = build_affected_purchase
      purchase.update_columns(flags: purchase.flags | Purchase.flag_mapping["flags"][:is_gift_sender_purchase])
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:credited]).to eq(1)
    end

    it "credits combined-charge purchases with gross_cents == total_transaction_cents (the per-purchase share)" do
      purchase = build_affected_purchase(price_cents: 4000, fee_cents: 596, affiliate_credit_cents: 340,
                                         total_transaction_cents: 4000)
      purchase.update_columns(flags: purchase.flags | Purchase.flag_mapping["flags"][:is_part_of_combined_charge])

      described_class.new(dry_run: false).process

      seller_leg = purchase.balance_transactions.order(:id).last
      expect(seller_leg.issued_amount_gross_cents).to eq(purchase.total_transaction_cents)
      expect(seller_leg.issued_amount_net_cents).to eq(purchase.payment_cents - purchase.affiliate_credit_cents.to_i)
    end

    it "credits a Collaborator-typed self-affiliate the same way" do
      collaborator = create(:collaborator, seller:, affiliate_user: seller)
      purchase = build_affected_purchase(affiliate: collaborator)
      expect do
        described_class.new(dry_run: false).process
      end.to change { purchase.balance_transactions.count }.from(1).to(2)
    end
  end

  describe "result shape" do
    it "verbose: false (default) leaves @skipped empty for non-error skips" do
      purchase = build_affected_purchase
      purchase.update!(stripe_refunded: true)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:refunded]).to eq(1)
      expect(result[:skipped]).to be_empty
    end

    it "credit_summary captures purchase id, seller id, prices, fee, affiliate credit, and the credit amount" do
      purchase = build_affected_purchase(price_cents: 1000, fee_cents: 209, affiliate_credit_cents: 79)
      result = described_class.new(dry_run: false).process
      summary = result[:credited].first
      expect(summary[:purchase_id]).to eq(purchase.id)
      expect(summary[:seller_id]).to eq(seller.id)
      expect(summary[:price_cents]).to eq(1000)
      expect(summary[:fee_cents]).to eq(209)
      expect(summary[:affiliate_credit_cents]).to eq(79)
      expect(summary[:credited_cents]).to eq(1000 - 209 - 79)
    end

    it "across a mixed batch, credits eligible purchases and tags every skip with a reason" do
      eligible_1 = build_affected_purchase
      eligible_2 = build_affected_purchase
      refunded = build_affected_purchase
      refunded.update!(stripe_refunded: true)
      build_affected_purchase(affiliate: create(:direct_affiliate, seller:, affiliate_user: create(:user)))
      zero_credit = build_affected_purchase
      zero_credit.update_columns(affiliate_credit_cents: 0)

      result = described_class.new(dry_run: false, verbose: true).process

      expect(result[:stats][:credited]).to eq(2)
      expect(result[:credited].map { |c| c[:purchase_id] }).to match_array([eligible_1.id, eligible_2.id])
      expect(result[:stats][:refunded]).to eq(1)
      expect(result[:stats][:no_affiliate_credit]).to eq(1)
      # not_self is excluded by the SQL scope (affiliate_user_id != seller_id), so :scanned == 4
      expect(result[:stats][:scanned]).to eq(4)
    end

    it "dry run does not touch any Balance or Purchase row" do
      purchase = build_affected_purchase
      original_balance_amount = purchase.balance_transactions.first.balance.amount_cents
      original_fk = purchase.purchase_success_balance_id

      result = described_class.new(dry_run: true).process

      expect(result[:stats][:credited]).to eq(1)
      expect(purchase.balance_transactions.count).to eq(1)
      expect(purchase.balance_transactions.first.balance.reload.amount_cents).to eq(original_balance_amount)
      expect(purchase.reload.purchase_success_balance_id).to eq(original_fk)
    end

    it "dry run skips ReplicaLagWatcher.watch so it works when run against a replica connection" do
      build_affected_purchase
      expect(ReplicaLagWatcher).not_to receive(:watch)
      described_class.new(dry_run: true).process
    end

    it "live run calls ReplicaLagWatcher.watch per purchase to throttle replica lag" do
      build_affected_purchase
      expect(ReplicaLagWatcher).to receive(:watch).at_least(:once)
      described_class.new(dry_run: false).process
    end

    it "dry run does NOT acquire Purchase.lock or open a transaction (safe to run on a read replica)" do
      build_affected_purchase
      expect(Purchase).not_to receive(:lock)
      expect(ApplicationRecord).not_to receive(:transaction)
      described_class.new(dry_run: true).process
    end
  end
end
