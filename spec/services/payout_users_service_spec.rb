# frozen_string_literal: true

require "spec_helper"

describe PayoutUsersService, :vcr do
  let!(:payout_date) { Date.yesterday }
  let(:user1) { create(:user, should_paypal_payout_be_split: true) }
  let(:user2) { create(:user) }

  before do
    create(:tos_agreement, user: user1)
    create(:user_compliance_info, user: user1)

    create(:tos_agreement, user: user2)
    create(:user_compliance_info, user: user2)
  end

  shared_examples_for "PayoutUsersService#process specs" do
    before do
      create(:balance, amount_cents: 10_001_00, user: user1, date: payout_date - 3, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
      create(:balance, user: user1, date: payout_date - 2, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))

      create(:balance, amount_cents: 10_002_00, user: user2, date: payout_date - 3, merchant_account: merchant_account2)
      create(:balance, user: user2, date: payout_date - 2, merchant_account: merchant_account2)

      if payout_processor_type == PayoutProcessorType::STRIPE
        Stripe::Transfer.create(destination: merchant_account2.charge_processor_merchant_id, currency: "usd", amount: user2.unpaid_balance_cents)
      end
    end

    it "marks the balances as processing, alters the users' balances, and creates payments" do
      service_object = described_class.new(date_string: payout_date.to_s, processor_type: payout_processor_type,
                                           user_ids: [user1.id, user2.id])

      expect do
        expect(service_object).to receive(:create_payments).and_call_original
        result = service_object.process
        expect(result.length).to eq(2)
        expect(result.map(&:id)).to match_array([Payment.last.id, Payment.first.id])
        expect(result.map(&:processor).uniq).to eq([payout_processor_type])
      end.to change { Payment.count }.by(2)

      expect(Payment.last.payout_type).to eq(Payouts::PAYOUT_TYPE_STANDARD)
      expect(Payment.first.payout_type).to eq(Payouts::PAYOUT_TYPE_STANDARD)

      expect(user1.reload.unpaid_balance_cents).to eq(0)
      expect(user2.reload.unpaid_balance_cents).to eq(0)

      expect(user1.balances.reload.pluck(:state).uniq).to eq(["processing"])
      expect(user2.balances.reload.pluck(:state).uniq).to eq(["processing"])
    end

    it "works even if the supplied `user_ids` argument is not an array" do
      service_object = described_class.new(date_string: payout_date.to_s, processor_type: payout_processor_type,
                                           user_ids: user1.id)
      expect do
        result = service_object.process
        expect(result.length).to eq(1)
        expect(result.first.id).to eq(Payment.last.id)
        expect(result.first.processor).to eq(payout_processor_type)
      end.to change { Payment.count }.by(1)

      expect(user1.reload.unpaid_balance_cents).to eq(0)
      expect(Payment.last.payout_type).to eq(Payouts::PAYOUT_TYPE_STANDARD)

      expect(user1.balances.reload.pluck(:state).uniq).to eq(["processing"])
    end

    it "processes payments for all users even if there are exceptions in the process" do
      # Make processing the first user ID raise an exception
      allow(User).to receive(:find).and_call_original
      allow(Payouts).to receive(:create_payment).and_call_original
      allow(User).to receive(:find).with(user1.id).and_return(user1)
      allow(Payouts).to receive(:create_payment).with(payout_date.to_s, payout_processor_type, user1, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
                                                .and_raise(StandardError)

      service_object = described_class.new(date_string: payout_date.to_s, processor_type: payout_processor_type,
                                           user_ids: [user1.id, user2.id])
      expect do
        result = service_object.process
        expect(result.length).to eq(1)
        expect(result.first.id).to eq(Payment.last.id)
        expect(result.first.processor).to eq(payout_processor_type)
        expect(result.first.user_id).to eq(user2.id)
      end.to change { Payment.count }.by(1)

      expect(user1.reload.unpaid_balance_cents > 0).to eq(true)
      expect(user2.reload.unpaid_balance_cents).to eq(0)

      expect(Payment.last.payout_type).to eq(Payouts::PAYOUT_TYPE_STANDARD)

      expect(user1.balances.reload.pluck(:state).uniq).to eq(["unpaid"])
      expect(user2.balances.reload.pluck(:state).uniq).to eq(["processing"])
    end
  end

  describe "PayoutUsersService#create_payments" do
    it "returns array of payments and cross-border payments" do
      service_object = described_class.new(date_string: payout_date.to_s, processor_type: PayoutProcessorType::STRIPE, user_ids: user1.id)

      expect(user1.balances).to be_empty
      payments, cross_border_payments = service_object.create_payments
      expect(payments).to eq([])
      expect(cross_border_payments).to eq([])

      create(:balance, amount_cents: 10_00, user: user1, date: payout_date - 2, merchant_account: create(:merchant_account, user: user1))
      payments, cross_border_payments = service_object.create_payments
      expect(payments.pluck(:user_id, :state, :amount_cents)).to eq([[user1.id, "processing", 10_00]])
      expect(cross_border_payments).to eq([])
    end
  end

  context "when the processor_type is 'STRIPE'" do
    let!(:payout_processor_type) { PayoutProcessorType::STRIPE }
    let(:merchant_account1) { StripeMerchantAccountManager.create_account(user1.reload, passphrase: "1234") }
    let(:merchant_account2) { StripeMerchantAccountManager.create_account(user2.reload, passphrase: "1234") }

    before do
      create(:ach_account_stripe_succeed, user: user1)
      create(:ach_account_stripe_succeed, user: user2)

      stripe_account1 = Stripe::Account.retrieve(merchant_account1.charge_processor_merchant_id)
      stripe_account2 = Stripe::Account.retrieve(merchant_account2.charge_processor_merchant_id)
      stripe_account1.refresh until stripe_account1.payouts_enabled?
      stripe_account2.refresh until stripe_account2.payouts_enabled?
    end

    include_examples "PayoutUsersService#process specs"

    it "does not process cross-border payouts immediately and schedules for 25 hours later" do
      allow_any_instance_of(UserComplianceInfo).to receive(:legal_entity_country_code).and_return("TH")
      expect(StripePayoutProcessor).not_to receive(:process_payments)

      service_object = described_class.new(date_string: payout_date.to_s, processor_type: payout_processor_type,
                                           user_ids: [user1.id, user2.id])
      expect do
        result = service_object.process
        expect(result.length).to eq(2)
        expect(result.first.id).to eq(user1.payments.last.id)
        expect(result.first.processor).to eq(payout_processor_type)
        expect(result.first.user_id).to eq(user1.id)
        expect(result.last.id).to eq(user2.payments.last.id)
        expect(result.last.processor).to eq(payout_processor_type)
        expect(result.last.user_id).to eq(user2.id)
      end.to change { Payment.processing.count }.by(2)

      expect(user1.reload.unpaid_balance_cents).to eq(0)
      expect(user2.reload.unpaid_balance_cents).to eq(0)
      expect(user1.balances.reload.pluck(:state).uniq).to eq(["processing"])
      expect(user2.balances.reload.pluck(:state).uniq).to eq(["processing"])
      expect(ProcessPaymentWorker).to have_enqueued_sidekiq_job(user1.payments.last.id).in(25.hours)
      expect(ProcessPaymentWorker).to have_enqueued_sidekiq_job(user2.payments.last.id).in(25.hours)
    end

    it "marks the balances as processing, alters the users' balances, and creates payments when payout method is instant" do
      bal1 = user1.unpaid_balances.where("amount_cents > 1000000").last
      bal1.update!(amount_cents: 9_989_00, holding_amount_cents: 9_989_00)
      bal2 = user2.unpaid_balances.where("amount_cents > 1000000").last
      bal2.update!(amount_cents: 990_00, holding_amount_cents: 990_00)

      service_object = described_class.new(date_string: payout_date.to_s, processor_type: payout_processor_type,
                                           user_ids: [user1.id, user2.id], payout_type: Payouts::PAYOUT_TYPE_INSTANT)

      expect do
        expect(service_object).to receive(:create_payments).and_call_original
        result = service_object.process
        expect(result.length).to eq(2)
        expect(result.map(&:id)).to match_array([Payment.last.id, Payment.first.id])
        expect(result.map(&:processor).uniq).to eq([payout_processor_type])
      end.to change { Payment.count }.by(2)

      payment1 = user1.payments.last
      expect(payment1.payout_type).to eq(Payouts::PAYOUT_TYPE_INSTANT)
      expect(payment1.state).to eq("processing")
      expect(payment1.stripe_transfer_id).to match(/po_/)
      expect(payment1.stripe_connect_account_id).to match(/acct_/)
      expect(payment1.amount_cents).to eq 970776
      expect(payment1.gumroad_fee_cents).to eq 29123

      payment2 = user2.payments.last
      expect(payment2.payout_type).to eq(Payouts::PAYOUT_TYPE_INSTANT)
      expect(payment2.state).to eq("processing")
      expect(payment2.stripe_transfer_id).to match(/po_/)
      expect(payment2.stripe_connect_account_id).to match(/acct_/)
      expect(payment2.amount_cents).to eq 97087
      expect(payment2.gumroad_fee_cents).to eq 2913

      expect(user1.reload.unpaid_balance_cents).to eq(0)
      expect(user2.reload.unpaid_balance_cents).to eq(0)

      expect(user1.balances.reload.pluck(:state).uniq).to eq(["processing"])
      expect(user2.balances.reload.pluck(:state).uniq).to eq(["processing"])
    end

    it "marks the payments as failed if the instant payout amount is more than the limit" do
      bal1 = user1.unpaid_balances.where("amount_cents > 1000000").last
      bal1.update!(amount_cents: 12_000_00, holding_amount_cents: 12_000_00)
      bal2 = user2.unpaid_balances.where("amount_cents > 1000000").last
      bal2.update!(amount_cents: 13_000_00, holding_amount_cents: 13_000_00)

      stripe_account1 = Stripe::Account.retrieve(user1.stripe_account.charge_processor_merchant_id)
      stripe_account2 = Stripe::Account.retrieve(user2.stripe_account.charge_processor_merchant_id)
      stripe_account1.refresh until stripe_account1.payouts_enabled?
      stripe_account2.refresh until stripe_account2.payouts_enabled?
      Stripe::Transfer.create(destination: merchant_account2.charge_processor_merchant_id, currency: "usd", amount: user2.unpaid_balance_cents)

      service_object = described_class.new(date_string: payout_date.to_s, processor_type: payout_processor_type,
                                           user_ids: [user1.id, user2.id], payout_type: Payouts::PAYOUT_TYPE_INSTANT)

      expect do
        expect(service_object).to receive(:create_payments).and_call_original
        result = service_object.process
        expect(result.length).to eq(2)
        expect(result.map(&:id)).to match_array([Payment.last.id, Payment.first.id])
        expect(result.map(&:processor).uniq).to eq([payout_processor_type])
      end.to change { Payment.count }.by(2)

      Payment.last(2).each do |payment|
        expect(payment.payout_type).to eq(Payouts::PAYOUT_TYPE_INSTANT)
        expect(payment.state).to eq("failed")
      end

      expect(user1.reload.unpaid_balance_cents).to eq(12_010_00)
      expect(user2.reload.unpaid_balance_cents).to eq(13_010_00)

      expect(user1.balances.reload.pluck(:state).uniq).to eq(["unpaid"])
      expect(user2.balances.reload.pluck(:state).uniq).to eq(["unpaid"])
    end
  end

  context "when the processor_type is 'PAYPAL'" do
    let!(:payout_processor_type) { PayoutProcessorType::PAYPAL }
    let(:merchant_account1) { MerchantAccount.gumroad(PaypalChargeProcessor::DISPLAY_NAME) }
    let(:merchant_account2) { merchant_account1 }

    before do
      allow(PaypalPayoutProcessor).to receive(:perform_payments)
      allow(PaypalPayoutProcessor).to receive(:perform_split_payment)
    end

    include_examples "PayoutUsersService#process specs"

    it "processes cross-border payouts immediately" do
      user1.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info, user: user2, country: "Thailand")
      user2.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info, user: user2, country: "Brazil")
      expect(PaypalPayoutProcessor).to receive(:process_payments)

      service_object = described_class.new(date_string: payout_date.to_s, processor_type: payout_processor_type,
                                           user_ids: [user1.id, user2.id])
      expect do
        result = service_object.process
        expect(result.length).to eq(2)
        expect(result.first.id).to eq(user1.payments.last.id)
        expect(result.first.processor).to eq(payout_processor_type)
        expect(result.first.user_id).to eq(user1.id)
        expect(result.first.amount_cents).to eq(9_810_78)
        expect(result.first.gumroad_fee_cents).to eq(200_22)
        expect(result.last.id).to eq(user2.payments.last.id)
        expect(result.last.processor).to eq(payout_processor_type)
        expect(result.last.user_id).to eq(user2.id)
        expect(result.last.amount_cents).to eq(10_012_00)
        expect(result.last.gumroad_fee_cents).to eq(nil)
      end.to change { Payment.processing.count }.by(2)

      expect(user1.reload.unpaid_balance_cents).to eq(0)
      expect(user2.reload.unpaid_balance_cents).to eq(0)
      expect(user1.balances.reload.pluck(:state).uniq).to eq(["processing"])
      expect(user2.balances.reload.pluck(:state).uniq).to eq(["processing"])
      expect(ProcessPaymentWorker.jobs.size).to eq(0)
    end
  end
end
