# frozen_string_literal: true

require "spec_helper"

describe PaypalPayoutProcessor do
  describe "is_user_payable" do
    let(:user) { create(:singaporean_user_with_compliance_info, payment_address: "seller@gr.co") }

    describe "creator has not set a payment address" do
      before do
        user.update!(payment_address: "")
      end

      it "returns false" do
        expect(described_class.is_user_payable(user, 10_01)).to eq(false)
      end

      it "adds a payout skipped note if the flag is set" do
        expect do
          described_class.is_user_payable(user, 10_01)
        end.not_to change { user.comments.with_type_payout_note.count }

        expect do
          described_class.is_user_payable(user, 10_01, add_comment: true)
        end.to change { user.comments.with_type_payout_note.count }.by(1)

        content = "Payout via PayPal on #{Time.current.to_fs(:formatted_date_full_month)} skipped because the account does not have a valid PayPal payment address"
        expect(user.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "returns true if creator has a paypal account connected", :vcr do
        create(:merchant_account_paypal, user:, charge_processor_merchant_id: "B66YJBBNCRW6L")
        expect(described_class.is_user_payable(user, 10_01)).to eq(true)
      end
    end

    describe "creator has set a payment address" do
      it "returns true" do
        expect(described_class.is_user_payable(user, 10_01)).to eq(true)
      end

      describe "when the user has a previous payout in processing state" do
        before do
          @payout1 = create(:payment, user:, txn_id: "dummy", processor_fee_cents: 10)
          @payout2 = create(:payment, user:, txn_id: "dummy2", processor_fee_cents: 20)
        end

        it "returns false " do
          expect(described_class.is_user_payable(user, 10_01)).to eq(false)

          user.payments.processing.each { |payment| payment.mark_completed! }
          expect(described_class.is_user_payable(user, 10_01)).to eq(true)
        end

        it "adds a payout skipped note if the flag is set" do
          expect do
            described_class.is_user_payable(user, 10_01)
          end.not_to change { user.comments.with_type_payout_note.count }

          expect do
            described_class.is_user_payable(user, 10_01, add_comment: true)
          end.to change { user.comments.with_type_payout_note.count }.by(1)

          date = Time.current.to_fs(:formatted_date_full_month)
          content = "Payout via PayPal on #{date} skipped because there are already payouts (ID #{@payout1.id}, #{@payout2.id}) in processing"
          expect(user.comments.with_type_payout_note.last.content).to eq(content)
        end
      end

      describe "payment address contains non-ascii characters" do
        before do
          user.payment_address = "sebastian.ripenås@example.com"
        end

        it "returns false" do
          expect(described_class.is_user_payable(user, 10_01)).to eq(false)
        end

        it "adds a payout skipped note if the flag is set" do
          expect do
            described_class.is_user_payable(user, 10_01)
          end.not_to change { user.comments.with_type_payout_note.count }

          expect do
            described_class.is_user_payable(user, 10_01, add_comment: true)
          end.to change { user.comments.with_type_payout_note.count }.by(1)

          date = Time.current.to_fs(:formatted_date_full_month)
          content = "Payout via PayPal on #{date} skipped because the PayPal payment address contains invalid characters"
          expect(user.comments.with_type_payout_note.last.content).to eq(content)
        end
      end

      describe "creator has an active bank account" do
        before do
          create(:ach_account, user:)
        end

        it "returns false" do
          expect(described_class.is_user_payable(user, 10_01)).to eq(false)
        end

        it "does not add a payout skipped note" do
          expect do
            described_class.is_user_payable(user, 10_01)
          end.not_to change { user.comments.with_type_payout_note.count }

          expect do
            described_class.is_user_payable(user, 10_01, add_comment: true)
          end.not_to change { user.comments.with_type_payout_note.count }
        end
      end

      describe "creator is payable via Stripe" do
        before do
          allow(StripePayoutProcessor).to receive(:is_user_payable).and_return true
        end

        it "returns false" do
          expect(described_class.is_user_payable(user, 10_01)).to eq(false)
        end

        it "does not add a payout skipped note" do
          expect do
            described_class.is_user_payable(user, 10_01)
          end.not_to change { user.comments.with_type_payout_note.count }

          expect do
            described_class.is_user_payable(user, 10_01, add_comment: true)
          end.not_to change { user.comments.with_type_payout_note.count }
        end
      end
    end
  end

  describe "has_valid_payout_info?" do
    let(:user) { create(:user_with_compliance_info, payment_address: "user@example.com") }

    it "returns true if the user has valid payout info" do
      expect(user.has_valid_payout_info?).to eq true
    end

    it "returns false if the user is missing a payment address" do
      user.payment_address = ""
      expect(user.has_valid_payout_info?).to eq false
    end

    it "returns false if the user has an invalid payment address" do
      user.payment_address = "foo"
      expect(user.has_valid_payout_info?).to eq false
      user.payment_address = "user&nbsp;@example.co,m"
      expect(user.has_valid_payout_info?).to eq false
    end

    it "returns false if the user hasn't provided their compliance info" do
      user.alive_user_compliance_info.destroy!
      expect(user.has_valid_payout_info?).to eq false
    end

    it "returns true if the user has a PayPal account connected", :vcr do
      user.update!(payment_address: "")
      expect(user.reload.has_valid_payout_info?).to eq false

      create(:merchant_account_paypal, user:, charge_processor_merchant_id: "B66YJBBNCRW6L")
      expect(user.reload.has_valid_payout_info?).to eq true
    end
  end

  describe "is_balance_payable" do
    describe "balance is associated with a Gumroad merchant account" do
      let(:balance) { create(:balance) }

      it "returns true" do
        expect(described_class.is_balance_payable(balance)).to eq(true)
      end
    end

    describe "balance is associated with a Creators' merchant account" do
      let(:merchant_account) { create(:merchant_account) }
      let(:balance) { create(:balance, merchant_account:) }

      it "returns false" do
        expect(described_class.is_balance_payable(balance)).to eq(false)
      end
    end
  end

  describe "prepare_payment_and_set_amount" do
    let(:user) { create(:singaporean_user_with_compliance_info) }
    let(:balance_1) { create(:balance, user:, date: Date.today - 1, currency: Currency::USD, amount_cents: 10_00) }
    let(:balance_2) { create(:balance, user:, date: Date.today - 2, currency: Currency::USD, amount_cents: 20_00) }
    let(:payment) do
      payment = create(:payment, user:, currency: nil, amount_cents: nil)
      payment.balances << balance_1
      payment.balances << balance_2
      payment
    end

    before do
      described_class.prepare_payment_and_set_amount(payment, [balance_1, balance_2])
    end

    it "sets the currency" do
      expect(payment.currency).to eq(Currency::USD)
    end

    it "sets the amount as the sum of the balances" do
      expect(payment.amount_cents).to eq(29_40)
      expect(payment.gumroad_fee_cents).to eq(60)
    end
  end

  describe ".enqueue_payments" do
    let!(:yesterday) { Date.yesterday.to_s }
    let!(:user_ids) { (1..5000).to_a }

    it "enqueues PayoutUsersWorker jobs for the supplied payments" do
      # Assert that a fake delay is supplied to get around rate-limits
      user_ids.each_slice(240).with_index do |ids, index|
        expect(PayoutUsersWorker).to receive(:perform_in)
                                       .with(index.minutes, yesterday, PayoutProcessorType::PAYPAL, ids)
                                       .once.and_call_original
      end

      described_class.enqueue_payments(user_ids, yesterday)

      # Assert that the jobs are enqueued
      expect(PayoutUsersWorker.jobs.size).to eq(user_ids.size / 240 + 1)
      sidekiq_job_args = user_ids.each_slice(240).each_with_object([]) do |ids, accumulator|
        accumulator << [yesterday, PayoutProcessorType::PAYPAL, ids]
      end
      expect(PayoutUsersWorker.jobs.map { _1["args"] }).to match_array(sidekiq_job_args)
    end
  end

  describe ".process_payments" do
    # Will not be split because the user does not have the `should_paypal_payout_be_split` flag set
    let(:payment1) { create(:payment, amount_cents: described_class::MAX_SPLIT_PAYMENT_BY_CENTS + 1) }
    # Will be split
    let(:payment2) do create(:payment, user: create(:user, should_paypal_payout_be_split: true),
                                       amount_cents: described_class::MAX_SPLIT_PAYMENT_BY_CENTS + 1) end
    # Will be split
    let(:payment3) do create(:payment, user: create(:user, should_paypal_payout_be_split: true),
                                       amount_cents: described_class::MAX_SPLIT_PAYMENT_BY_CENTS * 2) end
    # Will not be split because the amount can be sent in 1 request
    let(:payment4) do create(:payment, user: create(:user, should_paypal_payout_be_split: true),
                                       amount_cents: described_class::MAX_SPLIT_PAYMENT_BY_CENTS) end
    # Regular payments
    let(:payment5) { create(:payment) }
    let(:payment6) { create(:payment) }
    # US creator payments
    let(:payment7) do
      user = create(:user)
      create(:user_compliance_info, user:)
      expect(user.signed_up_from_united_states?).to eq(true)
      create(:payment, user:)
    end
    let(:payment8) do
      user = create(:user)
      create(:user_compliance_info, user:)
      expect(user.signed_up_from_united_states?).to eq(true)
      create(:payment, user:)
    end
    # Will be split because the amount is greater than the split payout size set for the user
    let(:payment9) do
      create(:payment, amount_cents: 19_000_00,
                       user: create(:user, should_paypal_payout_be_split: true, split_payment_by_cents: 10_000_00))
    end
    # Will be split because the payout amount is greater than the maximum split payout size
    let(:payment10) do
      create(:payment, amount_cents: 21_000_00,
                       user: create(:user, should_paypal_payout_be_split: true, split_payment_by_cents: 30_000_00))
    end

    let(:payments) { [payment1, payment2, payment3, payment4, payment5, payment6, payment7, payment8, payment9, payment10] }

    it "calls payout methods with the correct payments" do
      allow(described_class).to receive(:perform_payments).with(anything)
      allow(described_class).to receive(:perform_split_payment).with(anything)

      expect(described_class).to receive(:perform_split_payment).with(payment2)
      expect(described_class).to receive(:perform_split_payment).with(payment3)
      expect(described_class).to receive(:perform_split_payment).with(payment9)
      expect(described_class).to receive(:perform_split_payment).with(payment10)
      expect(described_class).to receive(:perform_payments).with([payment1, payment4, payment5, payment6, payment7, payment8])

      described_class.process_payments(payments)
    end

    it "calls the correct methods for every payment even if exceptions are raised" do
      allow(described_class).to receive(:perform_payments).with(anything)
      allow(described_class).to receive(:perform_split_payment).with(payment3)

      # Make processing the first split payment raise an error
      allow(described_class).to receive(:perform_split_payment).with(payment2).and_raise(StandardError)

      # Assert that all methods are called as expected
      expect(described_class).to receive(:perform_split_payment).with(payment2)
      expect(described_class).to receive(:perform_split_payment).with(payment3)
      expect(described_class).to receive(:perform_split_payment).with(payment9)
      expect(described_class).to receive(:perform_split_payment).with(payment10)
      expect(described_class).to receive(:perform_payments).with([payment1, payment4, payment5, payment6, payment7, payment8])

      described_class.process_payments(payments)

      # Assert that processing the US payouts worked
      expect(payment7.reload.state).to eq("processing")
      expect(payment8.reload.state).to eq("processing")
    end
  end

  describe "pay via paypal and handle IPNs", :vcr do
    before do
      @u1 = create(:singaporean_user_with_compliance_info, payment_address: "amir_1351103838_biz@gumroad.com")
      @balance1_1 = create(:balance, user: @u1, amount_cents: 501, date: Date.today - 8)
      @balance1_2 = create(:balance, user: @u1, amount_cents: 500, date: Date.today - 9)

      @u2 = create(:singaporean_user_with_compliance_info, payment_address: "amir2_1351103838_biz@gumroad.com")
      @balance2 = create(:balance, user: @u2, amount_cents: 1002, date: Date.today - 8)

      @u3 = create(:singaporean_user_with_compliance_info, payment_address: "")
      create(:merchant_account_paypal, user: @u3, charge_processor_merchant_id: "B66YJBBNCRW6L")
      @balance3 = create(:balance, user: @u3, amount_cents: 1003, date: Date.today - 8)

      @u4 = create(:singaporean_user_with_compliance_info, payment_address: "amir4_1351103838_biz@gumroad.com")
      create(:merchant_account_paypal, user: @u4, charge_processor_merchant_id: "B66YJBBNCRW6L")
      @balance4 = create(:balance, user: @u4, amount_cents: 1004, date: Date.today - 8)

      WebMock.stub_request(:post, PAYPAL_ENDPOINT)
             .to_return(body: "TIMESTAMP=2012%2d10%2d26T20%3a29%3a14Z&CORRELATIONID=c51c5e0cecbce&ACK=Success&VERSION=90%2e0&BUILD=4072860")
    end

    it "creates the correct payment objects and update them once the IPN comes in" do
      Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, User.holding_balance)

      p1 = @u1.payments.last
      p2 = @u2.payments.last
      p3 = @u3.payments.last
      p4 = @u4.payments.last

      expect(p1.state).to eq "processing"
      expect(p2.state).to eq "processing"
      expect(p3.state).to eq "processing"
      expect(p4.state).to eq "processing"

      expect(@balance1_1.reload.state).to eq "processing"
      expect(@balance1_2.reload.state).to eq "processing"
      expect(@balance2.reload.state).to eq "processing"
      expect(@balance3.reload.state).to eq "processing"
      expect(@balance4.reload.state).to eq "processing"

      expect(p1.balances.size).to eq 2
      expect(p1.balances).to include(@balance1_1)
      expect(p1.balances).to include(@balance1_2)
      expect(p2.balances).to eq [@balance2]
      expect(p3.balances).to eq [@balance3]
      expect(p4.balances).to eq [@balance4]

      expect(p1.gumroad_fee_cents).to eq (@u1.balances.processing.sum(:amount_cents) * PaypalPayoutProcessor::PAYPAL_PAYOUT_FEE_PERCENT / 100.0).ceil
      expect(p1.amount_cents).to eq @u1.balances.processing.sum(:amount_cents) - p1.gumroad_fee_cents
      expect(p2.gumroad_fee_cents).to eq (@u2.balances.processing.sum(:amount_cents) * PaypalPayoutProcessor::PAYPAL_PAYOUT_FEE_PERCENT / 100.0).ceil
      expect(p2.amount_cents).to eq @u2.balances.processing.sum(:amount_cents) - p2.gumroad_fee_cents
      expect(p3.gumroad_fee_cents).to eq (@u3.balances.processing.sum(:amount_cents) * PaypalPayoutProcessor::PAYPAL_PAYOUT_FEE_PERCENT / 100.0).ceil
      expect(p3.amount_cents).to eq @u3.balances.processing.sum(:amount_cents) - p3.gumroad_fee_cents
      expect(p4.gumroad_fee_cents).to eq (@u4.balances.processing.sum(:amount_cents) * PaypalPayoutProcessor::PAYPAL_PAYOUT_FEE_PERCENT / 100.0).ceil
      expect(p4.amount_cents).to eq @u4.balances.processing.sum(:amount_cents) - p4.gumroad_fee_cents

      expect(p1.payment_address).to eq @u1.payment_address
      expect(p2.payment_address).to eq @u2.payment_address
      expect(p3.payment_address).to eq @u3.paypal_connect_account.paypal_account_details["primary_email"]
      expect(p4.payment_address).to eq @u4.payment_address

      described_class.handle_paypal_event("payment_date" => p1.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => p1.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn1",
                                          "status_0" => "Completed",
                                          "unique_id_0" => p1.id,
                                          "mc_fee_0" => "2.99",
                                          "receiver_email_1" => p2.user.payment_address,
                                          "masspay_txn_id_1" => "sometxn2",
                                          "status_1" => "Failed",
                                          "reason_code_1" => "1002",
                                          "unique_id_1" => p2.id,
                                          "mc_fee_1" => "3.99",
                                          "receiver_email_2" => p3.user.paypal_connect_account.paypal_account_details["primary_email"],
                                          "masspay_txn_id_2" => "sometxn3",
                                          "status_2" => "Unclaimed",
                                          "unique_id_2" => p3.id,
                                          "mc_fee_2" => "3.59",
                                          "receiver_email_3" => p4.user.payment_address,
                                          "masspay_txn_id_3" => "sometxn3",
                                          "status_3" => "Unclaimed",
                                          "unique_id_3" => p4.id,
                                          "mc_fee_3" => "3.59")

      expect(p1.reload.state).to eq "completed"
      expect(p2.reload.state).to eq "failed"
      expect(p3.reload.state).to eq "unclaimed"
      expect(p4.reload.state).to eq "unclaimed"

      expect(@balance1_1.reload.state).to eq "paid"
      expect(@balance1_2.reload.state).to eq "paid"
      expect(@balance2.reload.state).to eq "unpaid"
      expect(@balance3.reload.state).to eq "processing"
      expect(@balance4.reload.state).to eq "processing"

      expect(p1.txn_id).to eq "sometxn1"
      expect(p2.txn_id).to eq "sometxn2"
      expect(p3.txn_id).to eq "sometxn3"

      expect(p1.processor_fee_cents).to eq 299
      expect(p2.processor_fee_cents).to eq 399
      expect(p3.processor_fee_cents).to eq 359

      expect(@u1.reload.unpaid_balance_cents).to eq 0
      expect(@u2.reload.unpaid_balance_cents).to eq 1002
      expect(@u3.reload.unpaid_balance_cents).to eq 0
      expect(@u4.reload.unpaid_balance_cents).to eq 0

      expect(p2.failure_reason).to eq("PAYPAL 1002")

      described_class.handle_paypal_event("payment_date" => p3.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => p3.user.paypal_connect_account.paypal_account_details["primary_email"],
                                          "masspay_txn_id_0" => "sometxn3",
                                          "status_0" => "Completed",
                                          "unique_id_0" => p3.id,
                                          "mc_fee_0" => "3.59",
                                          "receiver_email_1" => p4.user.payment_address,
                                          "masspay_txn_id_1" => "sometxn3",
                                          "status_1" => "Returned",
                                          "unique_id_1" => p4.id,
                                          "mc_fee_1" => "3.59")
      p3 = p3.reload
      p4 = p4.reload
      expect(p3.state).to eq "completed"
      expect(p4.state).to eq "returned"

      expect(@balance3.reload.state).to eq "paid"
      expect(@balance4.reload.state).to eq "unpaid"

      expect(@u3.reload.unpaid_balance_cents).to eq 0
      expect(@u4.reload.unpaid_balance_cents).to eq 1004
    end

    it "decreases the user's balance by the amount of the payment and not down to 0" do
      Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, User.holding_balance)

      @u1.reload
      create(:balance, user: @u1, amount_cents: 99)

      p1 = @u1.payments.last
      p2 = @u2.payments.last
      described_class.handle_paypal_event("payment_date" => p1.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_10" => p1.user.payment_address,
                                          "masspay_txn_id_10" => "sometxn1",
                                          "status_10" => "Completed",
                                          "unique_id_10" => p1.id,
                                          "mc_fee_10" => "2.99",
                                          "receiver_email_11" => p2.user.payment_address,
                                          "masspay_txn_id_11" => "sometxn2",
                                          "status_11" => "Failed",
                                          "unique_id_11" => p2.id,
                                          "mc_fee_11" => "3.99")

      @u1.reload
      p2.reload

      expect(@u1.unpaid_balance_cents).to eq 99
      expect(p2.state).to eq "failed"
      expect(p2.failure_reason).to be_nil
    end

    it "behaves idempotently" do
      Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, User.holding_balance)

      @u1.reload
      create(:balance, user: @u1, amount_cents: 99)

      p1 = @u1.payments.last
      p2 = @u2.payments.last
      described_class.handle_paypal_event("payment_date" => p1.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_10" => p1.user.payment_address,
                                          "masspay_txn_id_10" => "sometxn1",
                                          "status_10" => "Completed",
                                          "unique_id_10" => p1.id,
                                          "mc_fee_10" => "2.99",
                                          "receiver_email_11" => p2.user.payment_address,
                                          "masspay_txn_id_11" => "sometxn2",
                                          "status_11" => "Failed",
                                          "unique_id_11" => p2.id,
                                          "mc_fee_11" => "3.99")

      @u1.reload
      expect(@u1.unpaid_balance_cents).to eq 99

      described_class.handle_paypal_event("payment_date" => p1.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_10" => p1.user.payment_address,
                                          "masspay_txn_id_10" => "sometxn1",
                                          "status_10" => "Completed",
                                          "unique_id_10" => p1.id,
                                          "mc_fee_10" => "2.99",
                                          "receiver_email_11" => p2.user.payment_address,
                                          "masspay_txn_id_11" => "sometxn2",
                                          "status_11" => "Failed",
                                          "unique_id_11" => p2.id,
                                          "mc_fee_11" => "3.99")
      @u1.reload
      expect(@u1.unpaid_balance_cents).to eq 99
    end

    describe "more" do
      before do
        @u1 = create(:singaporean_user_with_compliance_info, payment_address: "bob1@example.com")
        @balance1_1 = create(:balance, user: @u1, amount_cents: 1_000, date: Date.today - 10)
        @balance1_2 = create(:balance, user: @u1, amount_cents: 2_000, date: Date.today - 9)
        @balance1_3 = create(:balance, user: @u1, amount_cents: 3_000, date: Date.today - 8)
        @balance1_4 = create(:balance, user: @u1, amount_cents: 4_000, date: Date.today)

        @u2 = create(:singaporean_user_with_compliance_info, payment_address: "bob1@example.com")
        @balance2_1 = create(:balance, user: @u2, amount_cents: 10_000, date: Date.today - 10)
        @balance2_2 = create(:balance, user: @u2, amount_cents: 20_000, date: Date.today - 9)
        @balance2_3 = create(:balance, user: @u2, amount_cents: 30_000, date: Date.today - 8)
        @balance2_4 = create(:balance, user: @u2, amount_cents: 40_000, date: Date.today)

        @u3 = create(:singaporean_user_with_compliance_info)
        @balance3 = create(:balance, user: @u3, amount_cents: 4_000)
      end

      it "creates the proper payments and mark the balances and make the association between those" do
        WebMock.stub_request(:post, PAYPAL_ENDPOINT)
          .to_return(body: "TIMESTAMP=2012%2d10%2d26T20%3a29%3a14Z&CORRELATIONID=c51c5e0cecbce&ACK=Success&VERSION=90%2e0&BUILD=4072860")
        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, User.holding_balance)

        expect(@balance1_1.reload.state).to eq "processing"
        expect(@balance1_2.reload.state).to eq "processing"
        expect(@balance1_3.reload.state).to eq "processing"
        expect(@balance1_4.reload.state).to eq "unpaid"
        expect(@balance2_1.reload.state).to eq "processing"
        expect(@balance2_2.reload.state).to eq "processing"
        expect(@balance2_3.reload.state).to eq "processing"
        expect(@balance2_4.reload.state).to eq "unpaid"
        expect(@balance3.reload.state).to eq "unpaid"

        expect(@u1.reload.unpaid_balance_cents).to eq 4_000
        expect(@u2.reload.unpaid_balance_cents).to eq 40_000
        expect(@u3.reload.unpaid_balance_cents).to eq 4_000

        p1 = @u1.payments.last
        p2 = @u2.payments.last

        expect(@balance1_1.payments).to eq [p1]
        expect(@balance1_2.payments).to eq [p1]
        expect(@balance1_3.payments).to eq [p1]
        expect(@balance1_4.payments).to eq []
        expect(@balance2_1.payments).to eq [p2]
        expect(@balance2_2.payments).to eq [p2]
        expect(@balance2_3.payments).to eq [p2]
        expect(@balance2_4.payments).to eq []
        expect(@balance3.payments).to eq []

        described_class.handle_paypal_event("payment_date" => p1.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                            "receiver_email_0" => p1.user.payment_address,
                                            "masspay_txn_id_0" => "sometxn1",
                                            "status_0" => "Completed",
                                            "unique_id_0" => p1.id,
                                            "mc_fee_0" => "2.99",
                                            "receiver_email_1" => p2.user.payment_address,
                                            "masspay_txn_id_1" => "sometxn2",
                                            "status_1" => "Failed",
                                            "unique_id_1" => p2.id,
                                            "mc_fee_1" => "3.99                            ")

        expect(@u1.reload.unpaid_balance_cents).to eq 4000
        expect(@u2.reload.unpaid_balance_cents).to eq 100_000

        expect(@balance1_1.reload.state).to eq "paid"
        expect(@balance1_2.reload.state).to eq "paid"
        expect(@balance1_3.reload.state).to eq "paid"
        expect(@balance1_4.reload.state).to eq "unpaid"
        expect(@balance2_1.reload.state).to eq "unpaid"
        expect(@balance2_2.reload.state).to eq "unpaid"
        expect(@balance2_3.reload.state).to eq "unpaid"
        expect(@balance2_4.reload.state).to eq "unpaid"
        expect(@balance3.reload.state).to eq "unpaid"
      end

      it "marks the balances as unpaid if the paypal call fails" do
        WebMock.stub_request(:post, PAYPAL_ENDPOINT)
          .to_return(body: "TIMESTAMP=2012%2d10%2d26T20%3a29%3a14Z&CORRELATIONID=c51c5e0cecbce&ACK=Fail&VERSION=90%2e0&BUILD=4072860")
        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, User.holding_balance)

        expect(@balance1_1.reload.state).to eq "unpaid"
        expect(@balance1_2.reload.state).to eq "unpaid"
        expect(@balance1_3.reload.state).to eq "unpaid"
        expect(@balance1_4.reload.state).to eq "unpaid"
        expect(@balance2_1.reload.state).to eq "unpaid"
        expect(@balance2_2.reload.state).to eq "unpaid"
        expect(@balance2_3.reload.state).to eq "unpaid"
        expect(@balance2_4.reload.state).to eq "unpaid"
        expect(@balance3.reload.state).to eq "unpaid"

        expect(@u1.unpaid_balance_cents).to eq 10_000
        expect(@u2.unpaid_balance_cents).to eq 100_000
        expect(@u3.unpaid_balance_cents).to eq 4000

        p1 = @u1.payments.last
        p2 = @u2.payments.last

        expect(p1.state).to eq "failed"
        expect(p2.state).to eq "failed"
      end

      it "handles unclaimed payments properly" do
        WebMock.stub_request(:post, PAYPAL_ENDPOINT)
          .to_return(body: "TIMESTAMP=2012%2d10%2d26T20%3a29%3a14Z&CORRELATIONID=c51c5e0cecbce&ACK=Success&VERSION=90%2e0&BUILD=4072860")
        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, User.holding_balance)

        p1 = @u1.payments.last
        p2 = @u2.payments.last
        described_class.handle_paypal_event("payment_date" => p1.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                            "receiver_email_0" => p1.user.payment_address,
                                            "masspay_txn_id_0" => "sometxn1",
                                            "status_0" => "Unclaimed",
                                            "unique_id_0" => p1.id,
                                            "mc_fee_0" => "2.99",
                                            "receiver_email_1" => p2.user.payment_address,
                                            "masspay_txn_id_1" => "sometxn2",
                                            "status_1" => "Unclaimed",
                                            "unique_id_1" => p2.id,
                                            "mc_fee_1" => "3.99                            ")

        expect(@balance1_1.reload.state).to eq "processing"
        expect(@balance1_2.reload.state).to eq "processing"
        expect(@balance1_3.reload.state).to eq "processing"
        expect(@balance1_4.reload.state).to eq "unpaid"
        expect(@balance2_1.reload.state).to eq "processing"
        expect(@balance2_2.reload.state).to eq "processing"
        expect(@balance2_3.reload.state).to eq "processing"
        expect(@balance2_4.reload.state).to eq "unpaid"

        described_class.handle_paypal_event("payment_date" => p1.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                            "receiver_email_0" => p1.user.payment_address,
                                            "masspay_txn_id_0" => "sometxn1",
                                            "status_0" => "Returned",
                                            "unique_id_0" => p1.id,
                                            "mc_fee_0" => "2.99",
                                            "receiver_email_1" => p2.user.payment_address,
                                            "masspay_txn_id_1" => "sometxn2",
                                            "status_1" => "Completed",
                                            "unique_id_1" => p2.id,
                                            "mc_fee_1" => "3.99                            ")

        expect(@balance1_1.reload.state).to eq "unpaid"
        expect(@balance1_2.reload.state).to eq "unpaid"
        expect(@balance1_3.reload.state).to eq "unpaid"
        expect(@balance1_4.reload.state).to eq "unpaid"
        expect(@balance2_1.reload.state).to eq "paid"
        expect(@balance2_2.reload.state).to eq "paid"
        expect(@balance2_3.reload.state).to eq "paid"
        expect(@balance2_4.reload.state).to eq "unpaid"

        expect(@u1.reload.unpaid_balance_cents).to eq 10_000
        expect(@u2.reload.unpaid_balance_cents).to eq 40_000
        expect(@u3.reload.unpaid_balance_cents).to eq 4000
      end

      it "gets correct latest status from paypal for payments with pending status" do
        paypal_response_stub = { "L_TIMESTAMP0" => "2018-08-16T06:56:13Z", "L_TIMEZONE0" => "GMT", "L_TYPE0" => "Payment", "L_EMAIL0" => "gumbot@gumroad.com",
                                 "L_NAME0" => "Gumbot", "L_TRANSACTIONID0" => "8KC32848U35842026", "L_STATUS0" => "Completed", "L_AMT0" => "-1066.80",
                                 "L_CURRENCYCODE0" => "USD", "L_FEEAMT0" => "-2.99", "L_NETAMT0" => "-1069.79", "TIMESTAMP" => "2018-08-16T08:07:09Z",
                                 "CORRELATIONID" => "357a5b454bd3d", "ACK" => "Success", "VERSION" => "90.0", "BUILD" => "46457558" }
        WebMock.stub_request(:post, PAYPAL_ENDPOINT).to_return(body: paypal_response_stub.to_query)
        Payouts.create_payments_for_balances_up_to_date_for_users(Date.yesterday, PayoutProcessorType::PAYPAL, User.holding_balance)
        p1 = @u1.payments.last
        described_class.handle_paypal_event("payment_date" => p1.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                            "receiver_email_0" => p1.user.payment_address,
                                            "masspay_txn_id_0" => "sometxn1",
                                            "status_0" => "Pending",
                                            "unique_id_0" => p1.id,
                                            "mc_fee_0" => "2.99")

        expect(p1.reload.state).to eq "completed"
      end

      it "enqueues a job to set the status from PayPal for payments with pending status" do
        paypal_response_stub = { "TIMESTAMP" => "2018-08-16T08:07:09Z", "CORRELATIONID" => "357a5b454bd3d", "ACK" => "Success", "VERSION" => "90.0", "BUILD" => "46457558" }
        WebMock.stub_request(:post, PAYPAL_ENDPOINT).to_return(body: paypal_response_stub.to_query)

        Payouts.create_payments_for_balances_up_to_date_for_users(Date.yesterday, PayoutProcessorType::PAYPAL, User.holding_balance)

        payment1 = @u1.payments.last
        payment2 = @u2.payments.last

        described_class.handle_paypal_event("payment_date" => payment1.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                            "receiver_email_0" => payment1.user.payment_address,
                                            "masspay_txn_id_0" => "sometxn12",
                                            "status_0" => "Pending",
                                            "unique_id_0" => payment1.id,
                                            "mc_fee_0" => "29.99",
                                            "receiver_email_1" => payment2.user.payment_address,
                                            "masspay_txn_id_1" => "sometxn23",
                                            "status_1" => "Completed",
                                            "unique_id_1" => payment2.id,
                                            "mc_fee_1" => "39.99")

        payment1.reload
        payment2.reload

        expect(UpdatePayoutStatusWorker).to have_enqueued_sidekiq_job(payment1.id)
        expect(payment1.state).to eq("processing")
        expect(payment2.state).to eq("completed")
        expect(payment1.processor_fee_cents).to eq(2999)
        expect(payment2.processor_fee_cents).to eq(3999)
        expect(payment1.txn_id).to eq("sometxn12")
        expect(payment2.txn_id).to eq("sometxn23")
      end
    end

    describe "creator is not payable through paypal" do
      before do
        @u1 = create(:singaporean_user_with_compliance_info, payment_address: nil)
        @balance1_1 = create(:balance, user: @u1, amount_cents: 1_000, date: Date.today - 3)
        @balance1_2 = create(:balance, user: @u1, amount_cents: 2_000, date: Date.today - 2)
        @balance1_3 = create(:balance, user: @u1, amount_cents: 3_000, date: Date.today - 1)
        @balance1_4 = create(:balance, user: @u1, amount_cents: 4_000, date: Date.today)
      end

      it "does not create a Payment object" do
        expect do
          Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@u1])
        end.not_to change { Payment.count }
      end
    end
  end

  describe "perform_payment_in_split_mode" do
    before do
      @creator = create(:singaporean_user_with_compliance_info, payment_address: "amir_1351103838_biz@gumroad.com", should_paypal_payout_be_split: true)
      @balance1_1 = create(:balance, user: @creator, amount_cents: 20_000_00, date: Date.today - 9)
      @balance1_2 = create(:balance, user: @creator, amount_cents: 1_000_00, date: Date.today - 10)
      WebMock.stub_request(:post, PAYPAL_ENDPOINT)
             .to_return(body: "TIMESTAMP=2012%2d10%2d26T20%3a29%3a14Z&CORRELATIONID=c51c5e0cecbce&ACK=Success&VERSION=90%2e0&BUILD=4072860")
    end

    it "creates the correct payment objects and update them once the IPN comes in" do
      Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@creator])

      payment = @creator.payments.last
      expect(payment.was_created_in_split_mode).to eq true
      expect(payment.state).to eq "processing"
      expect(@balance1_1.reload.state).to eq "processing"
      expect(@balance1_2.reload.state).to eq "processing"
      expect(payment.balances.size).to eq 2
      expect(payment.balances).to include(@balance1_1)
      expect(payment.balances).to include(@balance1_2)

      expect(payment.gumroad_fee_cents).to eq (@creator.balances.processing.sum(:amount_cents) * PaypalPayoutProcessor::PAYPAL_PAYOUT_FEE_PERCENT / 100.0).ceil
      expect(payment.amount_cents).to eq @creator.balances.processing.sum(:amount_cents) - payment.gumroad_fee_cents
      expect(payment.payment_address).to eq @creator.payment_address
    end
  end

  describe "handle_paypal_event_for_split_payment" do
    before do
      @creator = create(:singaporean_user_with_compliance_info, payment_address: "amir_1351103838_biz@gumroad.com", should_paypal_payout_be_split: true)
      @balance1_1 = create(:balance, user: @creator, amount_cents: 21_000_00, date: Date.today - 9)
      @balance1_2 = create(:balance, user: @creator, amount_cents: 1_000_00, date: Date.today - 10)
      WebMock.stub_request(:post, PAYPAL_ENDPOINT)
             .to_return(body: "TIMESTAMP=2012%2d10%2d26T20%3a29%3a14Z&CORRELATIONID=c51c5e0cecbce&ACK=Success&VERSION=90%2e0&BUILD=4072860")
    end

    it "creates the correct payment objects and update them once the IPN comes in" do
      Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@creator])

      payment = @creator.payments.last
      expect(payment.was_created_in_split_mode).to eq true
      expect(payment.state).to eq "processing"
      expect(@balance1_1.reload.state).to eq "processing"
      expect(@balance1_2.reload.state).to eq "processing"
      expect(payment.balances.size).to eq 2
      expect(payment.balances).to include(@balance1_1)
      expect(payment.balances).to include(@balance1_2)

      expect(payment.gumroad_fee_cents).to eq (@creator.balances.processing.sum(:amount_cents) * PaypalPayoutProcessor::PAYPAL_PAYOUT_FEE_PERCENT / 100.0).ceil
      expect(payment.amount_cents).to eq @creator.balances.processing.sum(:amount_cents) - payment.gumroad_fee_cents
      expect(payment.payment_address).to eq @creator.payment_address

      # IPN for the first split payment:
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn1",
                                          "status_0" => "Completed",
                                          "unique_id_0" => "#{PaypalPayoutProcessor::SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-1",
                                          "mc_fee_0" => "3")

      expect(payment.reload.state).to eq "processing"
      expect(@balance1_1.reload.state).to eq "processing"
      expect(@balance1_2.reload.state).to eq "processing"
      expect(payment.processor_fee_cents).to eq 300
      expect(@creator.reload.unpaid_balance_cents).to eq 0

      # IPN for the second split payment:
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn2",
                                          "status_0" => "Completed",
                                          "unique_id_0" => "#{PaypalPayoutProcessor::SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-2",
                                          "mc_fee_0" => "2")

      expect(payment.reload.state).to eq "completed"

      expect(payment.split_payments_info[0]["amount_cents"]).to eq 20_000_00
      expect(payment.split_payments_info[1]["amount_cents"]).to eq 1_560_00
      expect(payment.split_payments_info[0]["errors"]).to eq []
      expect(payment.split_payments_info[1]["errors"]).to eq []
      expect(payment.split_payments_info[0]["state"]).to eq "completed"
      expect(payment.split_payments_info[1]["state"]).to eq "completed"
      expect(payment.split_payments_info[0]["txn_id"]).to eq "sometxn1"
      expect(payment.split_payments_info[1]["txn_id"]).to eq "sometxn2"
      expect(payment.processor_fee_cents).to eq 500
    end

    it "enqueues a job to set the status from PayPal for payments with pending status" do
      Payouts.create_payments_for_balances_up_to_date_for_users(Date.yesterday, PayoutProcessorType::PAYPAL, [@creator])
      payment = @creator.payments.last
      expect(payment.was_created_in_split_mode).to eq true

      # IPN for the first split payment
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn1",
                                          "status_0" => "Pending",
                                          "unique_id_0" => "#{PaypalPayoutProcessor::SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-1",
                                          "mc_fee_0" => "3")
      # IPN for the second split payment
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn2",
                                          "status_0" => "Completed",
                                          "unique_id_0" => "#{PaypalPayoutProcessor::SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-2",
                                          "mc_fee_0" => "2")

      expect(UpdatePayoutStatusWorker).to have_enqueued_sidekiq_job(payment.id)

      expect(payment.reload.state).to eq "processing"
      expect(payment.split_payments_info[0]["state"]).to eq "pending"
      expect(payment.split_payments_info[1]["state"]).to eq "completed"
    end

    it "transitions the split payment from pending to completed on correct IPN from paypal" do
      paypal_response_stub = { "TIMESTAMP" => "2018-08-16T08:07:09Z", "CORRELATIONID" => "357a5b454bd3d", "ACK" => "Success", "VERSION" => "90.0", "BUILD" => "46457558" }
      WebMock.stub_request(:post, PAYPAL_ENDPOINT).to_return(body: paypal_response_stub.to_query)
      Payouts.create_payments_for_balances_up_to_date_for_users(Date.yesterday, PayoutProcessorType::PAYPAL, [@creator])
      payment = @creator.payments.last
      expect(payment.was_created_in_split_mode).to eq true

      # IPN for the first split payment
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn1",
                                          "status_0" => "Pending",
                                          "unique_id_0" => "#{PaypalPayoutProcessor::SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-1",
                                          "mc_fee_0" => "3")
      # IPN for the second split payment
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn2",
                                          "status_0" => "Completed",
                                          "unique_id_0" => "#{PaypalPayoutProcessor::SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-2",
                                          "mc_fee_0" => "2")

      expect(payment.reload.state).to eq "processing"
      expect(payment.split_payments_info[0]["state"]).to eq "pending"
      expect(payment.split_payments_info[1]["state"]).to eq "completed"

      # IPN for the first split payment again with status as completed
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn1",
                                          "status_0" => "Completed",
                                          "unique_id_0" => "#{PaypalPayoutProcessor::SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-1",
                                          "mc_fee_0" => "3")

      expect(payment.reload.state).to eq "completed"
      expect(payment.split_payments_info[0]["state"]).to eq "completed"
      expect(payment.split_payments_info[1]["state"]).to eq "completed"
    end

    it "is idempotent" do
      Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@creator])

      payment = @creator.payments.last

      # IPN for the first split payment:
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn1",
                                          "status_0" => "Completed",
                                          "unique_id_0" => "#{PaypalPayoutProcessor::SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-1",
                                          "mc_fee_0" => "3")
      # Duplicated IPN for the first split payment:
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn1",
                                          "status_0" => "Completed",
                                          "unique_id_0" => "#{PaypalPayoutProcessor::SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-1",
                                          "mc_fee_0" => "3")
      # IPN for the second split payment:
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn2",
                                          "status_0" => "Completed",
                                          "unique_id_0" => "#{PaypalPayoutProcessor::SPLIT_PAYMENT_UNIQUE_ID_PREFIX}#{payment.id}-2",
                                          "mc_fee_0" => "2")

      expect(payment.reload.state).to eq "completed"

      expect(payment.split_payments_info.count).to eq 2
      expect(payment.processor_fee_cents).to eq 500
    end
  end

  describe ".handle_paypal_event_for_non_split_payment" do
    before do
      @creator = create(:singaporean_user_with_compliance_info, payment_address: "amir_1351103838_biz@gumroad.com", should_paypal_payout_be_split: true)
      @balance1_1 = create(:balance, user: @creator, amount_cents: 2_000_00, date: Date.today - 9)
      @balance1_2 = create(:balance, user: @creator, amount_cents: 1_000_00, date: Date.today - 10)
      WebMock.stub_request(:post, PAYPAL_ENDPOINT)
          .to_return(body: "TIMESTAMP=2012%2d10%2d26T20%3a29%3a14Z&CORRELATIONID=c51c5e0cecbce&ACK=Success&VERSION=90%2e0&BUILD=4072860")
    end

    it "does not do anything if the payment is in a terminal state" do
      Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@creator])

      payment = @creator.payments.last
      expect(payment.was_created_in_split_mode).to eq false
      expect(payment.state).to eq "processing"
      expect(@balance1_1.reload.state).to eq "processing"
      expect(@balance1_2.reload.state).to eq "processing"
      expect(payment.balances.size).to eq 2
      expect(payment.balances).to include(@balance1_1)
      expect(payment.balances).to include(@balance1_2)

      expect(payment.gumroad_fee_cents).to eq (@creator.balances.processing.sum(:amount_cents) * PaypalPayoutProcessor::PAYPAL_PAYOUT_FEE_PERCENT / 100.0).ceil
      expect(payment.amount_cents).to eq @creator.balances.processing.sum(:amount_cents) - payment.gumroad_fee_cents
      expect(payment.payment_address).to eq @creator.payment_address

      # IPN for payment reversed:
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn",
                                          "status_0" => "Reversed",
                                          "unique_id_0" => "#{payment.id}",
                                          "mc_fee_0" => "3")

      expect(payment.reload.state).to eq "reversed"
      expect(payment.amount_cents).to eq 2_940_00
      expect(payment.gumroad_fee_cents).to eq 60_00
      expect(payment.txn_id).to eq "sometxn"
      expect(payment.processor_fee_cents).to eq 300

      # IPN for payment returned:
      described_class.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                          "receiver_email_0" => payment.user.payment_address,
                                          "masspay_txn_id_0" => "sometxn",
                                          "status_0" => "Returned",
                                          "unique_id_0" => "#{payment.id}",
                                          "mc_fee_0" => "3")

      expect(payment.reload.state).to eq "reversed"
      expect(payment.amount_cents).to eq 2_940_00
      expect(payment.gumroad_fee_cents).to eq 60_00
      expect(payment.txn_id).to eq "sometxn"
      expect(payment.processor_fee_cents).to eq 300
    end
  end

  describe ".split_payment_by_cents" do
    it "returns the value from the database if is present and less than the maximum" do
      user = create(:user, split_payment_by_cents: 5000_00)

      expect(described_class.split_payment_by_cents(user)).to eq(5000_00)
    end

    it "returns the maximum value if the database value is greater than the maximum" do
      user = create(:user, split_payment_by_cents: described_class::MAX_SPLIT_PAYMENT_BY_CENTS + 1)

      expect(described_class.split_payment_by_cents(user)).to eq(described_class::MAX_SPLIT_PAYMENT_BY_CENTS)
    end

    it "returns the maximum value if no value is present in the database" do
      user = create(:user)

      expect(described_class.split_payment_by_cents(user)).to eq(described_class::MAX_SPLIT_PAYMENT_BY_CENTS)
    end
  end

  describe "#search_payment_on_paypal", :vcr do
    it "searches transaction on PayPal using transaction id if it present" do
      amount_cents = 89771
      transaction_id = "75K708962P9301333"
      start_date = Date.new(2023, 12, 25).beginning_of_day - 1.day

      expected_response = { state: "completed", transaction_id:, correlation_id: "e168129b8a7bc", paypal_fee: "-17.95" }

      expect(described_class.search_payment_on_paypal(amount_cents:, transaction_id:, start_date:)).to eq(expected_response)
    end

    it "searches transaction on PayPal using amount, payment address, and period if transaction id is not present" do
      amount_cents = 89771
      payment_address = "sb-dmsfs3088295@business.example.com"
      start_date = Date.new(2023, 12, 25).beginning_of_day - 1.day
      end_date = Date.new(2023, 12, 25).end_of_day + 1.day

      expected_response = { state: "completed", transaction_id: "75K708962P9301333", correlation_id: "daef8e34fb2c0", paypal_fee: "-17.95" }

      expect(described_class.search_payment_on_paypal(amount_cents:, payment_address:, start_date:, end_date:)).to eq(expected_response)
    end

    it "raises error if more than one transaction found in the same period with same payment address and amount" do
      amount_cents = 89771
      payment_address = "sb-dmsfs3088295@business.example.com"
      start_date = Date.new(2023, 12, 28).beginning_of_day - 1.day
      end_date = Date.new(2023, 12, 28).end_of_day + 1.day

      error_message = "Multiple PayPal transactions found for sb-dmsfs3088295@business.example.com with amount 897.71 between 2023-12-27 00:00:00 UTC and 2023-12-29 23:59:59 UTC"
      expect do
        described_class.search_payment_on_paypal(amount_cents:, payment_address:, start_date:, end_date:)
      end.to raise_error(RuntimeError, error_message)
    end
  end
end
