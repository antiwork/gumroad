# frozen_string_literal: true

require "test_helper"
# StripeChargesHelper (under spec/support) has no RSpec load-time dependency; it
# just wraps Stripe::PaymentIntent/Charge creation. Require it directly so
# perform_payment setups can fund a real Stripe account exactly as the RSpec spec
# did — the resulting HTTP replays from the per-example VCR cassettes.
require Rails.root.join("spec", "support", "stripe_charges_helper")

# Ported from
# spec/business/payments/payouts/processor/stripe/stripe_payout_processor_spec.rb
# (part of the #5801 Minitest migration). StripePayoutProcessor is exercised as
# pure business logic: eligibility checks, payout preparation (currency/amount,
# internal transfers, drift detection), performing payouts against Stripe, and
# handling Stripe payout webhooks.
#
# The original spec is `:vcr`, so every example that touched HTTP recorded a
# cassette named after its describe/it chain. This suite mirrors that: each test
# that hits Stripe wraps its body in `VCR.use_cassette("<the same path>")` (see
# `with_cassette`). Examples that only stub Stripe (Mocha) or touch the DB make
# no HTTP and need no cassette, exactly as in the RSpec run. The RSpec file nests
# describe/context/it; this suite uses flat `test "..."` methods with per-section
# setup helpers, matching subscription_test/purchase_test.
class StripePayoutProcessorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper
  include CurrencyHelper
  include StripeChargesHelper

  # ---------------------------------------------------------------------------
  # is_user_payable
  # ---------------------------------------------------------------------------
  test "is_user_payable creator no longer has an ach account returns false" do
    with_cassette("is_user_payable/creator_no_longer_has_an_ach_account/returns_false") do
      setup_is_user_payable
      @b1.mark_deleted!
      assert_equal false, StripePayoutProcessor.is_user_payable(@u1, 10_01)
    end
  end

  test "is_user_payable creator no longer has an ach account adds a payout skipped note if the flag is set" do
    with_cassette("is_user_payable/creator_no_longer_has_an_ach_account/adds_a_payout_skipped_note_if_the_flag_is_set") do
      setup_is_user_payable
      @b1.mark_deleted!

      assert_no_difference -> { @u1.comments.with_type_payout_note.count } do
        StripePayoutProcessor.is_user_payable(@u1, 10_01)
      end
      assert_difference -> { @u1.comments.with_type_payout_note.count }, 1 do
        StripePayoutProcessor.is_user_payable(@u1, 10_01, add_comment: true)
      end

      content = "Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because a bank account wasn't added at the time."
      assert_equal content, @u1.comments.with_type_payout_note.last.content
    end
  end

  test "is_user_payable creator has a ach account without a corresponding stripe id returns false" do
    with_cassette("is_user_payable/creator_has_a_ach_account_without_a_corresponding_stripe_id/returns_false") do
      setup_is_user_payable
      @b1.stripe_bank_account_id = nil
      @b1.save!
      assert_equal false, StripePayoutProcessor.is_user_payable(@u1, 10_01)
    end
  end

  test "is_user_payable creator has a ach account without a corresponding stripe id adds a payout skipped note if the flag is set" do
    with_cassette("is_user_payable/creator_has_a_ach_account_without_a_corresponding_stripe_id/adds_a_payout_skipped_note_if_the_flag_is_set") do
      setup_is_user_payable
      @b1.stripe_bank_account_id = nil
      @b1.save!

      assert_no_difference -> { @u1.comments.with_type_payout_note.count } do
        StripePayoutProcessor.is_user_payable(@u1, 10_01)
      end
      assert_difference -> { @u1.comments.with_type_payout_note.count }, 1 do
        StripePayoutProcessor.is_user_payable(@u1, 10_01, add_comment: true)
      end

      content = "Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because the payout bank account was not correctly set up."
      assert_equal content, @u1.comments.with_type_payout_note.last.content
    end
  end

  test "is_user_payable creator does not have a merchant account returns false" do
    with_cassette("is_user_payable/creator_does_not_have_a_merchant_account/returns_false") do
      setup_is_user_payable
      @m1.mark_deleted!
      @u1.reload
      assert_equal false, StripePayoutProcessor.is_user_payable(@u1, 10_01)
    end
  end

  test "is_user_payable creator does not have a merchant account adds a payout skipped note if the flag is set" do
    with_cassette("is_user_payable/creator_does_not_have_a_merchant_account/adds_a_payout_skipped_note_if_the_flag_is_set") do
      setup_is_user_payable
      @m1.mark_deleted!
      @u1.reload

      assert_no_difference -> { @u1.comments.with_type_payout_note.count } do
        StripePayoutProcessor.is_user_payable(@u1, 10_01)
      end
      assert_difference -> { @u1.comments.with_type_payout_note.count }, 1 do
        StripePayoutProcessor.is_user_payable(@u1, 10_01, add_comment: true)
      end

      content = "Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because the payout bank account was not correctly set up."
      assert_equal content, @u1.comments.with_type_payout_note.last.content
    end
  end

  test "is_user_payable returns true when the user is marked as compliant" do
    with_cassette("is_user_payable/returns_true_when_the_user_is_marked_as_compliant") do
      setup_is_user_payable
      assert_equal true, StripePayoutProcessor.is_user_payable(@u1, 10_01)
    end
  end

  test "is_user_payable instant payouts returns true when the user has an eligible balance" do
    with_cassette("is_user_payable/instant_payouts/returns_true_when_the_user_has_an_eligible_balance") do
      setup_is_user_payable
      assert_equal true, StripePayoutProcessor.is_user_payable(@u1, 100_01, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
    end
  end

  test "is_user_payable instant payouts returns false when the user has a balance above the maximum instant payout amount" do
    with_cassette("is_user_payable/instant_payouts/returns_false_when_the_user_has_a_balance_above_the_maximum_instant_payout_amount") do
      setup_is_user_payable
      assert_equal false, StripePayoutProcessor.is_user_payable(@u3, 10_000_01, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
    end
  end

  test "is_user_payable instant payouts returns false when the user has a balance below the minimum instant payout amount" do
    with_cassette("is_user_payable/instant_payouts/returns_false_when_the_user_has_a_balance_below_the_minimum_instant_payout_amount") do
      setup_is_user_payable
      assert_equal false, StripePayoutProcessor.is_user_payable(@u1, 99_99, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
    end
  end

  test "is_user_payable when the user has a previous payout in processing state returns false" do
    with_cassette("is_user_payable/when_the_user_has_a_previous_payout_in_processing_state/returns_false") do
      setup_is_user_payable
      create_payment(user: @u1, processor: "STRIPE", processor_fee_cents: 10, stripe_transfer_id: "tr_1234", stripe_connect_account_id: "acct_1234")
      create_payment(user: @u1, processor: "STRIPE", processor_fee_cents: 20, stripe_transfer_id: "tr_5678", stripe_connect_account_id: "acct_1234")

      assert_equal false, StripePayoutProcessor.is_user_payable(@u1, 10_01)

      @u1.payments.processing.each(&:mark_completed!)
      assert_equal true, StripePayoutProcessor.is_user_payable(@u1, 10_01)
    end
  end

  test "is_user_payable when the user has a previous payout in processing state adds a payout skipped note if the flag is set" do
    with_cassette("is_user_payable/when_the_user_has_a_previous_payout_in_processing_state/adds_a_payout_skipped_note_if_the_flag_is_set") do
      setup_is_user_payable
      create_payment(user: @u1, processor: "STRIPE", processor_fee_cents: 10, stripe_transfer_id: "tr_1234", stripe_connect_account_id: "acct_1234")
      create_payment(user: @u1, processor: "STRIPE", processor_fee_cents: 20, stripe_transfer_id: "tr_5678", stripe_connect_account_id: "acct_1234")

      assert_no_difference -> { @u1.comments.with_type_payout_note.count } do
        StripePayoutProcessor.is_user_payable(@u1, 10_01)
      end
      assert_difference -> { @u1.comments.with_type_payout_note.count }, 1 do
        StripePayoutProcessor.is_user_payable(@u1, 10_01, add_comment: true)
      end

      date = Time.current.to_fs(:formatted_date_full_month)
      content = "Payout on #{date} was skipped because there was already a payout in processing."
      assert_equal content, @u1.comments.with_type_payout_note.last.content
    end
  end

  test "is_user_payable creator has a Stripe Connect account returns true" do
    with_cassette("is_user_payable/creator_has_a_Stripe_Connect_account/returns_true") do
      setup_is_user_payable
      setup_stripe_connect_for_u1
      assert_equal true, StripePayoutProcessor.is_user_payable(@u1, 10_01)
    end
  end

  test "is_user_payable creator has a Stripe Connect account returns false if Stripe Connect account is from Brazil" do
    with_cassette("is_user_payable/creator_has_a_Stripe_Connect_account/returns_false_if_Stripe_Connect_account_is_from_Brazil") do
      setup_is_user_payable
      setup_stripe_connect_for_u1
      @u1.stripe_connect_account.mark_deleted!
      create_merchant_account_stripe_connect(user: @u1, country: "BR", currency: "brl")
      assert_equal false, StripePayoutProcessor.is_user_payable(@u1, 10_01)
    end
  end

  # ---------------------------------------------------------------------------
  # has_valid_payout_info?
  # ---------------------------------------------------------------------------
  test "has_valid_payout_info? returns true if the user otherwise has valid payout info" do
    user = setup_has_valid_payout_info
    assert_equal true, user.has_valid_payout_info?
  end

  test "has_valid_payout_info? returns false if the user does not have an active bank account" do
    user = setup_has_valid_payout_info
    user.active_bank_account.destroy!
    assert_equal false, user.has_valid_payout_info?
  end

  test "has_valid_payout_info? returns false if the user's bank account is not linked to Stripe" do
    user = setup_has_valid_payout_info
    user.active_bank_account.update!(stripe_bank_account_id: "")
    assert_equal false, user.has_valid_payout_info?
  end

  test "has_valid_payout_info? returns false if the user does not have a Stripe account" do
    user = setup_has_valid_payout_info
    user.stripe_account.destroy!
    assert_equal false, user.has_valid_payout_info?
  end

  test "has_valid_payout_info? returns true if the user has a connected Stripe account regardless of other checks" do
    user = setup_has_valid_payout_info
    user.stubs(:has_stripe_account_connected?).returns(true)
    user.active_bank_account.destroy!
    assert_equal true, user.has_valid_payout_info?
  end

  # ---------------------------------------------------------------------------
  # is_balance_payable
  # ---------------------------------------------------------------------------
  test "is_balance_payable balance is associated with a Gumroad merchant account returns true" do
    balance = create_balance
    assert_equal true, StripePayoutProcessor.is_balance_payable(balance)
  end

  test "is_balance_payable balance is associated with a Creators' merchant account returns false" do
    balance = create_balance(merchant_account: create_merchant_account)
    assert_equal true, StripePayoutProcessor.is_balance_payable(balance)
  end

  test "is_balance_payable balance is associated with a Creators' merchant account but in the wrong currency for some reason returns false" do
    merchant_account = create_merchant_account(currency: Currency::USD)
    balance = create_balance(merchant_account:, currency: Currency::CAD)
    assert_equal false, StripePayoutProcessor.is_balance_payable(balance)
  end

  # ---------------------------------------------------------------------------
  # prepare_payment_and_set_amount
  # ---------------------------------------------------------------------------
  test "prepare_payment_and_set_amount sets the currency" do
    with_cassette("prepare_payment_and_set_amount/sets_the_currency") do
      setup_prepare_payment_cad
      assert_equal Currency::CAD, @payment.currency
    end
  end

  test "prepare_payment_and_set_amount sets the amount as the sum of the balances" do
    with_cassette("prepare_payment_and_set_amount/sets_the_amount_as_the_sum_of_the_balances") do
      setup_prepare_payment_cad
      assert_equal 300_00, @payment.amount_cents
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_payment_and_set_amount error handling
  # ---------------------------------------------------------------------------
  test "prepare_payment_and_set_amount error handling when the internal transfer fails because the account lacks required capabilities marks the payment as failed with a CANNOT_PAY failure reason" do
    setup_prepare_payment_error_handling
    StripeTransferInternallyToCreator.stubs(:transfer_funds_to_account).raises(capabilities_error)

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@gumroad_balance])

    assert_includes errors.first, "needs to have at least one of the following capabilities enabled"
    assert_equal "failed", @payment.reload.state
    assert_equal Payment::FailureReason::CANNOT_PAY, @payment.failure_reason
    assert_includes @payment.error_message, "capabilities enabled"
  end

  test "prepare_payment_and_set_amount error handling when the internal transfer fails because the account lacks required capabilities does not report the known account-state error to the error tracker" do
    setup_prepare_payment_error_handling
    StripeTransferInternallyToCreator.stubs(:transfer_funds_to_account).raises(capabilities_error)
    ErrorNotifier.expects(:notify).never

    StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@gumroad_balance])
  end

  test "prepare_payment_and_set_amount error handling when the internal transfer fails with an unexpected InvalidRequestError reports the error to the error tracker and marks the payment failed without a failure reason" do
    setup_prepare_payment_error_handling
    unexpected_error = Stripe::InvalidRequestError.new("No such destination: acct_gone", nil)
    StripeTransferInternallyToCreator.stubs(:transfer_funds_to_account).raises(unexpected_error)
    ErrorNotifier.expects(:notify).with(unexpected_error)

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@gumroad_balance])

    assert_includes errors.first, "No such destination"
    assert_equal "failed", @payment.reload.state
    assert_nil @payment.failure_reason
  end

  # ---------------------------------------------------------------------------
  # destination_balance_drift_error
  # ---------------------------------------------------------------------------
  test "destination_balance_drift_error when Stripe's available + pending balance is less than Gumroad's recorded held-at-Stripe balance marks the payment as failed with INSUFFICIENT_FUNDS before any internal transfer" do
    setup_drift
    stub_stripe_balance(available: 1_096_45, pending: 0)
    StripeTransferInternallyToCreator.expects(:transfer_funds_to_account).never

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])

    assert_includes errors.first, "Destination Stripe balance mismatch"
    assert_includes errors.first, "gap: 25969 cents"
    assert_equal "failed", @payment.reload.state
    assert_equal Payment::FailureReason::INSUFFICIENT_FUNDS, @payment.failure_reason
  end

  test "destination_balance_drift_error when Stripe's available + pending balance is less than Gumroad's recorded held-at-Stripe balance surfaces the drift message through payment.errors so admin endpoints get an informative response body" do
    setup_drift
    stub_stripe_balance(available: 1_096_45, pending: 0)

    StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])

    assert_includes @payment.errors.full_messages.first, "Destination Stripe balance mismatch"
    assert_includes @payment.errors.full_messages.first, "gap: 25969 cents"
  end

  test "destination_balance_drift_error when Stripe's available + pending balance is less than Gumroad's recorded held-at-Stripe balance when the seller has a retired Gumroad-managed account still holding funds names the retired account and its residual balance in the error message" do
    setup_drift
    stub_stripe_balance(available: 1_096_45, pending: 0)
    create_merchant_account(user: @user, charge_processor_merchant_id: "acct_retired_with_funds", currency: Currency::EUR, country: "ES", deleted_at: Time.current)
    Stripe::Balance.stubs(:retrieve).with({}, { stripe_account: "acct_retired_with_funds" }).returns(
      Stripe::Balance.construct_from(object: "balance", available: [{ amount: 25_969, currency: "eur" }], pending: [{ amount: 0, currency: "eur" }])
    )

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])

    assert_includes errors.first, "Destination Stripe balance mismatch"
    assert_includes errors.first, "acct_retired_with_funds holds 25969 eur cents"
    assert_includes errors.first, "retired Stripe account(s) still holding funds"
  end

  test "destination_balance_drift_error when Stripe's available + pending balance is less than Gumroad's recorded held-at-Stripe balance when the seller has a retired account but it holds nothing keeps the plain drift message without a retired-account hint" do
    setup_drift
    stub_stripe_balance(available: 1_096_45, pending: 0)
    create_merchant_account(user: @user, charge_processor_merchant_id: "acct_retired_empty", currency: Currency::EUR, country: "ES", deleted_at: Time.current)
    Stripe::Balance.stubs(:retrieve).with({}, { stripe_account: "acct_retired_empty" }).returns(
      Stripe::Balance.construct_from(object: "balance", available: [{ amount: 0, currency: "eur" }], pending: [{ amount: 0, currency: "eur" }])
    )

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])

    assert_includes errors.first, "Destination Stripe balance mismatch"
    assert_not_includes errors.first, "retired Stripe account(s)"
  end

  test "destination_balance_drift_error when Stripe's available + pending balance is less than Gumroad's recorded held-at-Stripe balance when reading the retired account's balance fails at Stripe still returns the drift error without the hint" do
    setup_drift
    stub_stripe_balance(available: 1_096_45, pending: 0)
    create_merchant_account(user: @user, charge_processor_merchant_id: "acct_retired_gone", currency: Currency::EUR, country: "ES", deleted_at: Time.current)
    Stripe::Balance.stubs(:retrieve).with({}, { stripe_account: "acct_retired_gone" }).raises(Stripe::PermissionError.new("account does not exist"))

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])

    assert_includes errors.first, "Destination Stripe balance mismatch"
    assert_not_includes errors.first, "retired Stripe account(s)"
  end

  test "destination_balance_drift_error when Stripe's pending balance covers the gap (funds settling, no true drift) does not flag drift because settling pending funds will land before next cycle" do
    setup_drift
    stub_stripe_balance(available: 1_096_45, pending: 26_000)

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])

    assert_equal [], errors
    assert_not_equal "failed", @payment.state
  end

  test "destination_balance_drift_error when Stripe reports negative pending (reversals/disputes/refunds in flight) but available covers the payout does not flag drift because negative pending is clamped at zero" do
    setup_drift
    stub_stripe_balance(available: 1_500_00, pending: -50_000)

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])

    assert_equal [], errors
    assert_not_equal "failed", @payment.state
  end

  test "destination_balance_drift_error when Stripe's available balance matches or exceeds Gumroad's recorded held-at-Stripe balance proceeds with the payout preparation" do
    setup_drift
    stub_stripe_balance(available: 1_400_00, pending: 0)

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])

    assert_equal [], errors
    assert_not_equal "failed", @payment.state
    assert_equal 1_356_14, @payment.amount_cents
  end

  test "destination_balance_drift_error when Stripe has no balance entry in the destination currency treats both available and pending as zero for the missing currency and fails with the full gap" do
    setup_drift
    stub_stripe_balance(available: 1_400_00, pending: 50_000, currency: "usd")

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])

    assert_includes errors.first, "Destination Stripe balance mismatch"
    assert_includes errors.first, "gap: 135614 cents"
    assert_equal "failed", @payment.reload.state
    assert_equal Payment::FailureReason::INSUFFICIENT_FUNDS, @payment.failure_reason
  end

  test "destination_balance_drift_error when the destination is a user-connected Stripe Standard account skips the drift check because Gumroad does not manage the destination balance" do
    setup_drift
    stripe_connect_account = create_merchant_account_stripe_connect(user: @user, currency: Currency::EUR)
    StripePayoutProcessor.stubs(:get_payout_details).returns([stripe_connect_account, [], [@eur_balance]])
    Stripe::Balance.expects(:retrieve).never

    StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])
  end

  test "destination_balance_drift_error when there are no balances held at Stripe skips the drift check" do
    setup_drift
    StripePayoutProcessor.stubs(:get_payout_details).returns([@eur_merchant_account, [], []])
    Stripe::Balance.expects(:retrieve).never

    StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [])
  end

  test "destination_balance_drift_error when the destination merchant account is KRW skips the drift check because KRW subunit conventions differ between Gumroad and Stripe" do
    setup_drift
    krw_merchant_account = create_merchant_account(user: @user, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::KRW, country: "KR")
    krw_balance = create_balance(user: @user, merchant_account: krw_merchant_account, holding_currency: Currency::KRW, holding_amount_cents: 100_00)
    StripePayoutProcessor.stubs(:get_payout_details).returns([krw_merchant_account, [], [krw_balance]])
    Stripe::Balance.expects(:retrieve).never

    StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [krw_balance])
  end

  test "destination_balance_drift_error when Stripe::Balance.retrieve raises Stripe::APIConnectionError lets the error propagate to the existing rescue and marks the payment failed" do
    setup_drift
    Stripe::Balance.stubs(:retrieve).raises(Stripe::APIConnectionError.new("connection failed"))

    e = assert_raises(Stripe::APIConnectionError) do
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])
    end
    assert_match(/connection failed/, e.message)
    assert_equal "failed", @payment.reload.state
    assert_includes @payment.error_message, "Stripe::APIConnectionError"
  end

  test "destination_balance_drift_error when Stripe::Balance.retrieve raises Stripe::InvalidRequestError (e.g. account_invalid) lets the error propagate to the existing rescue, returns the error message, and marks the payment failed" do
    setup_drift
    Stripe::Balance.stubs(:retrieve).raises(Stripe::InvalidRequestError.new("No such account", "stripe_account"))
    ErrorNotifier.expects(:notify)

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@eur_balance])

    assert_equal ["No such account"], errors
    assert_equal "failed", @payment.reload.state
    assert_includes @payment.error_message, "No such account"
  end

  # ---------------------------------------------------------------------------
  # prepare_payment_and_set_amount when merchant_account is nil
  # ---------------------------------------------------------------------------
  test "prepare_payment_and_set_amount when merchant_account is nil returns an error and marks the payment as failed" do
    user = create_user
    payment = create_payment(user:, currency: nil, amount_cents: nil)
    balance = create_balance(user:, merchant_account: create_merchant_account(user:))
    StripePayoutProcessor.stubs(:get_payout_details).returns([nil, [balance], []])

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(payment, [balance])

    assert_equal ["Cannot process payout: no valid merchant account found for user."], errors
    assert_equal "failed", payment.reload.state
  end

  # ---------------------------------------------------------------------------
  # alert_if_payout_credited_retired_account
  # ---------------------------------------------------------------------------
  test "alert_if_payout_credited_retired_account when the payout's account is no longer the user's active merchant account adds a payout note and notifies the error tracker" do
    user = create_user
    retired_account = create_merchant_account(user:, charge_processor_merchant_id: "acct_retired", charge_processor_alive_at: nil, deleted_at: Time.current)
    payment = create_payment(user:, processor: PayoutProcessorType::STRIPE, stripe_connect_account_id: retired_account.charge_processor_merchant_id, stripe_transfer_id: "po_test_returned")
    create_merchant_account(user:, charge_processor_merchant_id: "acct_active")

    ErrorNotifier.expects(:notify).with(
      regexp_matches(/retired Stripe account acct_retired/),
      payment_id: payment.id,
      user_id: user.id
    )

    StripePayoutProcessor.alert_if_payout_credited_retired_account(payment)

    note = user.reload.comments.with_type_payout_note.last
    assert_includes note.content, "[PAYOUT][DRIFT]"
    assert_includes note.content, "acct_retired"
    assert_includes note.content, "acct_active"
  end

  test "alert_if_payout_credited_retired_account when the user has no active merchant account at all still adds a payout note and notifies the error tracker" do
    user = create_user
    retired_account = create_merchant_account(user:, charge_processor_merchant_id: "acct_retired", charge_processor_alive_at: nil, deleted_at: Time.current)
    payment = create_payment(user:, processor: PayoutProcessorType::STRIPE, stripe_connect_account_id: retired_account.charge_processor_merchant_id, stripe_transfer_id: "po_test_returned")

    ErrorNotifier.expects(:notify)

    StripePayoutProcessor.alert_if_payout_credited_retired_account(payment)

    note = user.reload.comments.with_type_payout_note.last
    assert_includes note.content, "[PAYOUT][DRIFT]"
  end

  test "alert_if_payout_credited_retired_account when the payout's account is still the user's active merchant account does nothing" do
    user = create_user
    active_account = create_merchant_account(user:, charge_processor_merchant_id: "acct_live")
    payment = create_payment(user:, processor: PayoutProcessorType::STRIPE, stripe_connect_account_id: active_account.charge_processor_merchant_id, stripe_transfer_id: "po_test_returned")

    ErrorNotifier.expects(:notify).never

    assert_no_difference -> { user.comments.count } do
      StripePayoutProcessor.alert_if_payout_credited_retired_account(payment)
    end
  end

  test "alert_if_payout_credited_retired_account when the payout went to a user-connected Stripe Standard account does nothing because Gumroad does not manage that account's balance" do
    user = create_user
    connect_account = create_merchant_account_stripe_connect(user:)
    payment = create_payment(user:, processor: PayoutProcessorType::STRIPE, stripe_connect_account_id: connect_account.charge_processor_merchant_id, stripe_transfer_id: "po_test_returned")

    ErrorNotifier.expects(:notify).never

    assert_no_difference -> { user.comments.count } do
      StripePayoutProcessor.alert_if_payout_credited_retired_account(payment)
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_payment_and_set_amount when balance_transaction is nil
  # ---------------------------------------------------------------------------
  test "prepare_payment_and_set_amount when balance_transaction is nil raises an error after retries and marks the payment as failed" do
    setup_balance_transaction_nil
    Stripe::Charge.expects(:retrieve).times(3).returns(destination_payment_nil_bt)
    StripePayoutProcessor.expects(:sleep).with(2).twice

    e = assert_raises(RuntimeError) do
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
    end
    assert_match(/Balance transaction not yet available/, e.message)
    assert_equal "failed", @payment.reload.state
  end

  test "prepare_payment_and_set_amount when balance_transaction is nil succeeds when balance_transaction becomes available on retry" do
    setup_balance_transaction_nil
    Stripe::Charge.expects(:retrieve).times(2).returns(destination_payment_nil_bt, destination_payment_with_bt)
    StripePayoutProcessor.expects(:sleep).with(2).once

    errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)

    assert_equal [], errors
    assert_equal 200_00, @payment.amount_cents
  end

  # ---------------------------------------------------------------------------
  # prepare_payment_and_set_amount with currency-mismatched balances
  # ---------------------------------------------------------------------------
  test "prepare_payment_and_set_amount with currency-mismatched balances when a Gumroad-held balance has holding_currency != usd fails the payment with an explanatory error rather than summing across currencies" do
    with_cassette("prepare_payment_and_set_amount_with_currency-mismatched_balances/when_a_Gumroad-held_balance_has_holding_currency_usd/fails_the_payment_with_an_explanatory_error_rather_than_summing_across_currencies") do
      setup_currency_mismatch_gumroad_held

      errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@vnd_balance, @usd_balance])

      assert_match(/holding_currency that does not match the payout currency/, errors.first)
      assert_includes errors.first, @vnd_balance.id.to_s
      assert_equal "failed", @payment.reload.state
    end
  end

  test "prepare_payment_and_set_amount with currency-mismatched balances when a Gumroad-held balance has holding_currency != usd records the failure reason and message so the failure is not silent" do
    setup_currency_mismatch_gumroad_held

    StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@vnd_balance, @usd_balance])

    assert_equal Payment::FailureReason::CURRENCY_MISMATCH, @payment.reload.failure_reason
    assert_includes @payment.error_message, "does not match the payout currency"
  end

  test "prepare_payment_and_set_amount with currency-mismatched balances when a Gumroad-held balance has holding_currency != usd does not silently produce a $9.45 wire amount from $126.72 of seller balance" do
    with_cassette("prepare_payment_and_set_amount_with_currency-mismatched_balances/when_a_Gumroad-held_balance_has_holding_currency_usd/does_not_silently_produce_a_9_45_wire_amount_from_126_72_of_seller_balance") do
      setup_currency_mismatch_gumroad_held

      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [@vnd_balance, @usd_balance])

      assert_not_equal 9_45, @payment.amount_cents
    end
  end

  test "prepare_payment_and_set_amount with currency-mismatched balances when a Stripe-held balance has holding_currency != merchant_account.currency fails the payment with an explanatory error" do
    with_cassette("prepare_payment_and_set_amount_with_currency-mismatched_balances/when_a_Stripe-held_balance_has_holding_currency_merchant_account_currency/fails_the_payment_with_an_explanatory_error") do
      user = create_user
      payment = create_payment(user:, currency: nil, amount_cents: nil)
      cad_merchant_account = create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::CAD, country: "CA")
      cad_balance = create_balance(user:, merchant_account: cad_merchant_account, amount_cents: 200_00, holding_currency: Currency::CAD, holding_amount_cents: 200_00)
      mismatched_balance = create_balance(user:, merchant_account: cad_merchant_account, amount_cents: 0, holding_currency: Currency::USD, holding_amount_cents: -50_00)
      StripePayoutProcessor.stubs(:get_payout_details).returns([cad_merchant_account, [], [cad_balance, mismatched_balance]])

      errors = StripePayoutProcessor.prepare_payment_and_set_amount(payment, [cad_balance, mismatched_balance])

      assert_match(/holding_currency that does not match the payout currency/, errors.first)
      assert_includes errors.first, mismatched_balance.id.to_s
      assert_equal "failed", payment.reload.state
      assert_equal Payment::FailureReason::CURRENCY_MISMATCH, payment.reload.failure_reason
      assert_includes payment.error_message, "does not match the payout currency"
    end
  end

  # ---------------------------------------------------------------------------
  # filter_aggregate_payable_balances
  # ---------------------------------------------------------------------------
  test "filter_aggregate_payable_balances when total Gumroad-held USD is below the per-currency floor excludes the Gumroad-held USD balances so they roll forward" do
    setup_filter_aggregate
    tiny_usd_balance = create_balance(user: @user, merchant_account: @gumroad_merchant_account, holding_currency: Currency::USD, holding_amount_cents: 2)
    StripePayoutProcessor.stubs(:get_payout_details).returns([@gbp_merchant_account, [tiny_usd_balance], [@gbp_stripe_balance]])

    result = StripePayoutProcessor.filter_aggregate_payable_balances(@user, [@gbp_stripe_balance, tiny_usd_balance])

    assert_equal [@gbp_stripe_balance], result
  end

  test "filter_aggregate_payable_balances when total Gumroad-held USD clears the floor keeps every balance so the internal transfer goes through" do
    setup_filter_aggregate
    usd_balance_one = create_balance(user: @user, merchant_account: @gumroad_merchant_account, holding_currency: Currency::USD, holding_amount_cents: 60)
    usd_balance_two = create_balance(user: @user, merchant_account: @gumroad_merchant_account, holding_currency: Currency::USD, holding_amount_cents: 50)
    StripePayoutProcessor.stubs(:get_payout_details).returns([@gbp_merchant_account, [usd_balance_one, usd_balance_two], [@gbp_stripe_balance]])

    result = StripePayoutProcessor.filter_aggregate_payable_balances(@user, [@gbp_stripe_balance, usd_balance_one, usd_balance_two])

    assert_equal [@gbp_stripe_balance, usd_balance_one, usd_balance_two].sort_by(&:id), result.sort_by(&:id)
  end

  test "filter_aggregate_payable_balances when the merchant account currency is USD keeps the balance because no FX conversion is needed" do
    setup_filter_aggregate
    usd_merchant_account = create_merchant_account(user: @user, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::USD)
    tiny_usd_balance = create_balance(user: @user, merchant_account: @gumroad_merchant_account, holding_currency: Currency::USD, holding_amount_cents: 2)
    StripePayoutProcessor.stubs(:get_payout_details).returns([usd_merchant_account, [tiny_usd_balance], []])

    result = StripePayoutProcessor.filter_aggregate_payable_balances(@user, [tiny_usd_balance])

    assert_equal [tiny_usd_balance], result
  end

  test "filter_aggregate_payable_balances when no Gumroad-held balances are present returns the input unchanged" do
    setup_filter_aggregate
    StripePayoutProcessor.stubs(:get_payout_details).returns([@gbp_merchant_account, [], [@gbp_stripe_balance]])

    result = StripePayoutProcessor.filter_aggregate_payable_balances(@user, [@gbp_stripe_balance])

    assert_equal [@gbp_stripe_balance], result
  end

  test "filter_aggregate_payable_balances when merchant_account is nil returns the input unchanged so existing nil-merchant handling runs downstream" do
    setup_filter_aggregate
    orphan_balance = create_balance(user: @user, merchant_account: @gumroad_merchant_account, holding_currency: Currency::USD, holding_amount_cents: 2)
    StripePayoutProcessor.stubs(:get_payout_details).returns([nil, [orphan_balance], []])

    result = StripePayoutProcessor.filter_aggregate_payable_balances(@user, [orphan_balance])

    assert_equal [orphan_balance], result
  end

  test "filter_aggregate_payable_balances when balances is empty returns the empty array without calling get_payout_details" do
    setup_filter_aggregate
    StripePayoutProcessor.expects(:get_payout_details).never

    assert_equal [], StripePayoutProcessor.filter_aggregate_payable_balances(@user, [])
  end

  # ---------------------------------------------------------------------------
  # prepare_payment_and_set_amount for Korean bank account
  # ---------------------------------------------------------------------------
  test "prepare_payment_and_set_amount for Korean bank account sets the currency" do
    with_cassette("prepare_payment_and_set_amount_for_Korean_bank_account/sets_the_currency") do
      setup_prepare_payment_korean
      assert_equal Currency::KRW, @payment.currency
    end
  end

  test "prepare_payment_and_set_amount for Korean bank account sets the amount as the sum of the balances, converted to match the database for KRW" do
    with_cassette("prepare_payment_and_set_amount_for_Korean_bank_account/sets_the_amount_as_the_sum_of_the_balances_converted_to_match_the_database_for_KRW") do
      setup_prepare_payment_korean
      assert_equal 39640900, @payment.amount_cents
    end
  end

  # ---------------------------------------------------------------------------
  # .enqueue_payments / .process_payments
  # ---------------------------------------------------------------------------
  test ".enqueue_payments enqueues PayoutUsersWorker jobs for the supplied payments" do
    yesterday = Date.yesterday.to_s
    user_ids = [1, 2, 3, 4]

    StripePayoutProcessor.enqueue_payments(user_ids, yesterday)

    assert_equal user_ids.size, PayoutUsersWorker.jobs.size
    expected_args = user_ids.map { |user_id| [yesterday, PayoutProcessorType::STRIPE, user_id, Payouts::PAYOUT_TYPE_STANDARD] }
    assert_equal expected_args.sort, PayoutUsersWorker.jobs.map { _1["args"] }.sort
  end

  test ".process_payments calls `perform_payment` for every payment" do
    payment1 = create_payment
    payment2 = create_payment
    payment3 = create_payment

    StripePayoutProcessor.expects(:perform_payment).with(payment1)
    StripePayoutProcessor.expects(:perform_payment).with(payment2)
    StripePayoutProcessor.expects(:perform_payment).with(payment3)

    StripePayoutProcessor.process_payments([payment1, payment2, payment3])
  end

  # ---------------------------------------------------------------------------
  # perform_payment (US Gumroad-managed account)
  # ---------------------------------------------------------------------------
  test "perform_payment creates a transfer at stripe" do
    with_cassette("perform_payment/creates_a_transfer_at_stripe") do
      setup_perform_payment_us
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      calls = capture_and_call_original(Stripe::Payout, :create) do
        @errors = StripePayoutProcessor.perform_payment(@payment)
      end
      assert_equal 1, calls.size
      params, opts = calls.first[0]
      assert_equal expected_payout_params(payment: @payment, bank_account: @bank_account, amount: @payment_amount_cents, currency: "usd", method: Payouts::PAYOUT_TYPE_STANDARD, balances_for_metadata: @balances), params
      assert_equal({ stripe_account: @merchant_account.charge_processor_merchant_id }, opts)
      assert_empty @errors
    end
  end

  test "perform_payment marks the payment as processing" do
    with_cassette("perform_payment/marks_the_payment_as_processing") do
      setup_perform_payment_us
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "processing", @payment.state
    end
  end

  test "perform_payment stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_us
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_equal @merchant_account.charge_processor_merchant_id, @payment.stripe_connect_account_id
    end
  end

  test "perform_payment stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_match(/po_[a-zA-Z0-9]+/, @payment.stripe_transfer_id)
    end
  end

  test "perform_payment does not store an internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment/does_not_store_an_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_nil @payment.stripe_internal_transfer_id
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount creates a normal transfer" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/creates_a_normal_transfer") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      calls = capture_and_call_original(Stripe::Payout, :create) do
        @errors = StripePayoutProcessor.perform_payment(@payment)
      end
      assert_equal 1, calls.size
      params, opts = calls.first[0]
      assert_equal expected_payout_params(payment: @payment, bank_account: @bank_account, amount: @payment_amount_cents, currency: "usd", method: Payouts::PAYOUT_TYPE_STANDARD, balances_for_metadata: @payment.balances), params
      assert_equal({ stripe_account: @merchant_account.charge_processor_merchant_id }, opts)
      assert_empty @errors
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "processing", @payment.state
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_equal @merchant_account.charge_processor_merchant_id, @payment.stripe_connect_account_id
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_match(/po_[a-zA-Z0-9]+/, @payment.stripe_transfer_id)
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_nil @payment.stripe_internal_transfer_id
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails notifies error tracker" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      ErrorNotifier.expects(:notify)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails returns the errors" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/returns_the_errors") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert errors.present?
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails marks the payment as failed" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "failed", @payment.reload.state
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because the account cannot be paid returns the errors" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_the_account_cannot_be_paid/returns_the_errors") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create live transfers: The account has fields needed.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert errors.present?
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because the account cannot be paid marks the payment as failed" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_the_account_cannot_be_paid/marks_the_payment_as_failed") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create live transfers: The account has fields needed.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "failed", @payment.reload.state
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because the account cannot be paid marks the payment with a failure reason of cannot pay" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_the_account_cannot_be_paid/marks_the_payment_with_a_failure_reason_of_cannot_pay") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create live transfers: The account has fields needed.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal Payment::FailureReason::CANNOT_PAY, @payment.reload.failure_reason
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because the account cannot be paid adds a payout note to the user" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_the_account_cannot_be_paid/adds_a_payout_note_to_the_user") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create live transfers: The account has fields needed.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert_difference -> { @user.comments.with_type_payout_note.count }, 1 do
        StripePayoutProcessor.perform_payment(@payment)
      end
      assert_includes @user.comments.with_type_payout_note.last.content, "Stripe is unable to create payouts"
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because payouts cannot be created returns the errors" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_payouts_cannot_be_created/returns_the_errors") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create payouts; please contact us via https://support.stripe.com/contact with details for assistance.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert errors.present?
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because payouts cannot be created marks the payment as failed" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_payouts_cannot_be_created/marks_the_payment_as_failed") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create payouts; please contact us via https://support.stripe.com/contact with details for assistance.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "failed", @payment.reload.state
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because payouts cannot be created marks the payment with a failure reason of cannot pay" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_payouts_cannot_be_created/marks_the_payment_with_a_failure_reason_of_cannot_pay") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create payouts; please contact us via https://support.stripe.com/contact with details for assistance.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal Payment::FailureReason::CANNOT_PAY, @payment.reload.failure_reason
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because payouts cannot be created adds a payout note to the user" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_payouts_cannot_be_created/adds_a_payout_note_to_the_user") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create payouts; please contact us via https://support.stripe.com/contact with details for assistance.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert_difference -> { @user.comments.with_type_payout_note.count }, 1 do
        StripePayoutProcessor.perform_payment(@payment)
      end
      assert_includes @user.comments.with_type_payout_note.last.content, "Stripe is unable to create payouts"
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because of an unsupported reason notifies error tracker" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_of_an_unsupported_reason/notifies_error_tracker") do
      setup_perform_payment_us
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Food was not tasty.", "food_bad"))
      ErrorNotifier.expects(:notify)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount creates an internal transfer and a normal transfer" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/creates_an_internal_transfer_and_a_normal_transfer") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      transfer_calls = capture_and_call_original(Stripe::Transfer, :create) do
        StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      end
      assert_equal 1, transfer_calls.size
      # StripeTransferInternallyToCreator.transfer_funds_to_account calls
      # Stripe::Transfer.create with keyword arguments, so the params land in the
      # captured kwargs (index 1), not the positional args.
      assert_hash_includes({
                             amount: @balances_held_by_gumroad.sum(&:amount_cents),
                             currency: "usd",
                             destination: @merchant_account.charge_processor_merchant_id,
                             description: "Funds held by Gumroad for Payment #{@payment.external_id}.",
                             metadata: { payment: @payment.external_id, "balances{0}" => @balances_held_by_gumroad.map(&:external_id).join(",") },
                           }, transfer_calls.first[1])

      payout_calls = capture_and_call_original(Stripe::Payout, :create) do
        @errors = StripePayoutProcessor.perform_payment(@payment)
      end
      assert_equal 1, payout_calls.size
      params, opts = payout_calls.first[0]
      assert_hash_includes({
                             amount: @payment.amount_cents,
                             currency: @payment.currency,
                             destination: @bank_account.stripe_bank_account_id,
                             description: @payment.external_id,
                             statement_descriptor: "Gumroad",
                             method: Payouts::PAYOUT_TYPE_STANDARD,
                             metadata: { payment: @payment.external_id, "balances{0}" => @payment.balances.map(&:external_id).join(","), bank_account: @bank_account.external_id },
                           }, params)
      assert_equal({ stripe_account: @merchant_account.charge_processor_merchant_id }, opts)
      assert_empty @errors
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "processing", @payment.state
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_equal @merchant_account.charge_processor_merchant_id, @payment.stripe_connect_account_id
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_match(/po_[a-zA-Z0-9]+/, @payment.stripe_transfer_id)
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_match(/tr_[a-zA-Z0-9]+/, @payment.stripe_internal_transfer_id)
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails notifies error tracker" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      Stripe::Transfer.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      ErrorNotifier.expects(:notify)
      errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert errors.present?
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails returns the errors" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/returns_the_errors") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      Stripe::Transfer.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert errors.present?
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails marks the payment as failed" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      Stripe::Transfer.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert_equal "failed", @payment.reload.state
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails mocked creates a reversal for the internal transfer" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/mocked/creates_a_reversal_for_the_internal_transfer") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      internal_transfer = mocked_internal_transfer
      reversals = mock
      reversals.expects(:create)
      internal_transfer.stubs(:reversals).returns(reversals)
      Stripe::Transfer.expects(:create).returns(internal_transfer)
      Stripe::Charge.expects(:retrieve).returns(mocked_destination_payment)
      Stripe::Payout.expects(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      Stripe::Transfer.expects(:retrieve).with(internal_transfer.id).returns(internal_transfer)
      StripePayoutProcessor.expects(:create_credit_for_difference_from_reversed_internal_transfer)

      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe notifies error tracker" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/notifies_error_tracker") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      hitting_stripe_external_fails
      ErrorNotifier.expects(:notify)
      StripePayoutProcessor.perform_payment(@payment)
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe returns the errors" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/returns_the_errors") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      hitting_stripe_external_fails
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert errors.present?
    end
  end

  test "perform_payment the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe marks the payment as failed" do
    with_cassette("perform_payment/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/marks_the_payment_as_failed") do
      setup_perform_payment_us
      add_gumroad_held_balances_positive
      hitting_stripe_external_fails
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "failed", @payment.reload.state
    end
  end

  test "perform_payment transfer fails due to an invalid request (amount over balance of creator) returns an error" do
    with_cassette("perform_payment/transfer_fails_due_to_an_invalid_request_amount_over_balance_of_creator_/returns_an_error") do
      setup_perform_payment_us
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      @payment.amount_cents = 500_000
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert errors.present?
      assert_match(/You have insufficient funds in your Stripe account for this transfer/, errors.first)
      assert_equal Payment::FailureReason::INSUFFICIENT_FUNDS, @payment.reload.failure_reason
    end
  end

  # ---------------------------------------------------------------------------
  # perform_payment for a US account with instant payout method type
  # ---------------------------------------------------------------------------
  test "perform_payment for a US account with instant payout method type creates a transfer at stripe" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/creates_a_transfer_at_stripe") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      calls = capture_and_call_original(Stripe::Payout, :create) do
        @errors = StripePayoutProcessor.perform_payment(@payment)
      end
      assert_equal 1, calls.size
      params, opts = calls.first[0]
      assert_equal expected_payout_params(payment: @payment, bank_account: @bank_account, amount: instant_payout_amount(@payment_amount_cents), currency: "usd", method: Payouts::PAYOUT_TYPE_INSTANT, balances_for_metadata: @balances), params
      assert_equal({ stripe_account: @merchant_account.charge_processor_merchant_id }, opts)
      assert_empty @errors
    end
  end

  test "perform_payment for a US account with instant payout method type marks the payment as processing" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/marks_the_payment_as_processing") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "processing", @payment.state
    end
  end

  test "perform_payment for a US account with instant payout method type stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_equal @merchant_account.charge_processor_merchant_id, @payment.stripe_connect_account_id
    end
  end

  test "perform_payment for a US account with instant payout method type stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_match(/po_[a-zA-Z0-9]+/, @payment.stripe_transfer_id)
    end
  end

  test "perform_payment for a US account with instant payout method type does not store an internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/does_not_store_an_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_nil @payment.stripe_internal_transfer_id
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount creates a normal transfer" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/creates_a_normal_transfer") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      calls = capture_and_call_original(Stripe::Payout, :create) do
        @errors = StripePayoutProcessor.perform_payment(@payment)
      end
      assert_equal 1, calls.size
      params, opts = calls.first[0]
      assert_equal expected_payout_params(payment: @payment, bank_account: @bank_account, amount: instant_payout_amount(@payment_amount_cents), currency: "usd", method: Payouts::PAYOUT_TYPE_INSTANT, balances_for_metadata: @payment.balances), params
      assert_equal({ stripe_account: @merchant_account.charge_processor_merchant_id }, opts)
      assert_empty @errors
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "processing", @payment.state
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_equal @merchant_account.charge_processor_merchant_id, @payment.stripe_connect_account_id
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_match(/po_[a-zA-Z0-9]+/, @payment.stripe_transfer_id)
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_nil @payment.stripe_internal_transfer_id
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails notifies error tracker" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      ErrorNotifier.expects(:notify)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails returns the errors" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/returns_the_errors") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert errors.present?
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails marks the payment as failed" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "failed", @payment.reload.state
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because the account cannot be paid returns the errors" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_the_account_cannot_be_paid/returns_the_errors") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create live transfers: The account has fields needed.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert errors.present?
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because the account cannot be paid marks the payment as failed" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_the_account_cannot_be_paid/marks_the_payment_as_failed") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create live transfers: The account has fields needed.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "failed", @payment.reload.state
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because the account cannot be paid marks the payment with a failure reason of cannot pay" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_the_account_cannot_be_paid/marks_the_payment_with_a_failure_reason_of_cannot_pay") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create live transfers: The account has fields needed.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal Payment::FailureReason::CANNOT_PAY, @payment.reload.failure_reason
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because the account cannot be paid adds a payout note to the user" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_the_account_cannot_be_paid/adds_a_payout_note_to_the_user") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create live transfers: The account has fields needed.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert_difference -> { @user.comments.with_type_payout_note.count }, 1 do
        StripePayoutProcessor.perform_payment(@payment)
      end
      assert_includes @user.comments.with_type_payout_note.last.content, "Stripe is unable to create payouts"
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because payouts cannot be created returns the errors" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_payouts_cannot_be_created/returns_the_errors") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create payouts; please contact us via https://support.stripe.com/contact with details for assistance.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert errors.present?
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because payouts cannot be created marks the payment as failed" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_payouts_cannot_be_created/marks_the_payment_as_failed") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create payouts; please contact us via https://support.stripe.com/contact with details for assistance.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "failed", @payment.reload.state
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because payouts cannot be created marks the payment with a failure reason of cannot pay" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_payouts_cannot_be_created/marks_the_payment_with_a_failure_reason_of_cannot_pay") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create payouts; please contact us via https://support.stripe.com/contact with details for assistance.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal Payment::FailureReason::CANNOT_PAY, @payment.reload.failure_reason
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because payouts cannot be created adds a payout note to the user" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_payouts_cannot_be_created/adds_a_payout_note_to_the_user") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Cannot create payouts; please contact us via https://support.stripe.com/contact with details for assistance.", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert_difference -> { @user.comments.with_type_payout_note.count }, 1 do
        StripePayoutProcessor.perform_payment(@payment)
      end
      assert_includes @user.comments.with_type_payout_note.last.content, "Stripe is unable to create payouts"
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails because of an unsupported reason notifies error tracker" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails_because_of_an_unsupported_reason/notifies_error_tracker") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Food was not tasty.", "food_bad"))
      ErrorNotifier.expects(:notify)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount creates an internal transfer and a normal transfer" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/creates_an_internal_transfer_and_a_normal_transfer") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      transfer_calls = capture_and_call_original(Stripe::Transfer, :create) do
        StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      end
      assert_equal 1, transfer_calls.size
      assert_hash_includes({
                             amount: @balances_held_by_gumroad.sum(&:amount_cents),
                             currency: "usd",
                             destination: @merchant_account.charge_processor_merchant_id,
                             description: "Funds held by Gumroad for Payment #{@payment.external_id}.",
                             metadata: { payment: @payment.external_id, "balances{0}" => @balances_held_by_gumroad.map(&:external_id).join(",") },
                           }, transfer_calls.first[1])

      payout_calls = capture_and_call_original(Stripe::Payout, :create) do
        @errors = StripePayoutProcessor.perform_payment(@payment)
      end
      assert_equal 1, payout_calls.size
      params, opts = payout_calls.first[0]
      assert_hash_includes({
                             amount: @payment.amount_cents,
                             currency: @payment.currency,
                             destination: @bank_account.stripe_bank_account_id,
                             description: @payment.external_id,
                             statement_descriptor: "Gumroad",
                             method: Payouts::PAYOUT_TYPE_INSTANT,
                             metadata: { payment: @payment.external_id, "balances{0}" => @payment.balances.map(&:external_id).join(","), bank_account: @bank_account.external_id },
                           }, params)
      assert_equal({ stripe_account: @merchant_account.charge_processor_merchant_id }, opts)
      assert_empty @errors
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "processing", @payment.state
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_equal @merchant_account.charge_processor_merchant_id, @payment.stripe_connect_account_id
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_match(/po_[a-zA-Z0-9]+/, @payment.stripe_transfer_id)
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert_empty errors
      assert_match(/tr_[a-zA-Z0-9]+/, @payment.stripe_internal_transfer_id)
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails notifies error tracker" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      Stripe::Transfer.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      ErrorNotifier.expects(:notify)
      errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert errors.present?
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails returns the errors" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/returns_the_errors") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      Stripe::Transfer.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      errors = StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert errors.present?
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails marks the payment as failed" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      Stripe::Transfer.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert_equal "failed", @payment.reload.state
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails mocked creates a reversal for the internal transfer" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/mocked/creates_a_reversal_for_the_internal_transfer") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      internal_transfer = mocked_internal_transfer
      reversals = mock
      reversals.expects(:create)
      internal_transfer.stubs(:reversals).returns(reversals)
      Stripe::Transfer.expects(:create).returns(internal_transfer)
      Stripe::Charge.expects(:retrieve).returns(mocked_destination_payment)
      Stripe::Payout.expects(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      Stripe::Transfer.expects(:retrieve).with(internal_transfer.id).returns(internal_transfer)
      StripePayoutProcessor.expects(:create_credit_for_difference_from_reversed_internal_transfer)

      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe notifies error tracker" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/notifies_error_tracker") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      hitting_stripe_external_fails
      ErrorNotifier.expects(:notify)
      StripePayoutProcessor.perform_payment(@payment)
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe returns the errors" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/returns_the_errors") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      hitting_stripe_external_fails
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert errors.present?
    end
  end

  test "perform_payment for a US account with instant payout method type the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe marks the payment as failed" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/marks_the_payment_as_failed") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      add_gumroad_held_balances_positive
      hitting_stripe_external_fails
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "failed", @payment.reload.state
    end
  end

  test "perform_payment for a US account with instant payout method type transfer fails due to an invalid request (amount over balance of creator) returns an error" do
    with_cassette("perform_payment_for_a_US_account_with_instant_payout_method_type/transfer_fails_due_to_an_invalid_request_amount_over_balance_of_creator_/returns_an_error") do
      setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      @payment.amount_cents = 500_000
      errors = StripePayoutProcessor.perform_payment(@payment)
      assert errors.present?
      assert_match(/You have insufficient funds in your Stripe account for this transfer/, errors.first)
      assert_equal Payment::FailureReason::INSUFFICIENT_FUNDS, @payment.reload.failure_reason
    end
  end

  # ---------------------------------------------------------------------------
  # perform_payment with a Canadian payout
  # ---------------------------------------------------------------------------
  test "perform_payment with a Canadian payout creates a transfer at stripe" do
    with_cassette("perform_payment_with_a_Canadian_payout/creates_a_transfer_at_stripe") do
      setup_perform_payment_canadian
      assert_managed_creates_transfer
    end
  end

  test "perform_payment with a Canadian payout marks the payment as processing" do
    with_cassette("perform_payment_with_a_Canadian_payout/marks_the_payment_as_processing") do
      setup_perform_payment_canadian
      assert_managed_marks_processing
    end
  end

  test "perform_payment with a Canadian payout stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_with_a_Canadian_payout/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_canadian
      assert_managed_stores_account_id
    end
  end

  test "perform_payment with a Canadian payout stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_with_a_Canadian_payout/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_canadian
      assert_managed_stores_transfer_id
    end
  end

  test "perform_payment with a Canadian payout stores the stripe payout's arrival date on the payment" do
    with_cassette("perform_payment_with_a_Canadian_payout/stores_the_stripe_payout_s_arrival_date_on_the_payment") do
      setup_perform_payment_canadian
      assert_managed_stores_arrival_date
    end
  end

  test "perform_payment with a Canadian payout does not store an internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_with_a_Canadian_payout/does_not_store_an_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_canadian
      assert_managed_no_internal_transfer_id
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which don't sum to a positive amount creates a normal transfer" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/creates_a_normal_transfer") do
      setup_perform_payment_canadian
      assert_managed_dont_sum_creates_normal
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which don't sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_canadian
      assert_managed_dont_sum_marks_processing
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_canadian
      assert_managed_dont_sum_stores_account_id
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_canadian
      assert_managed_dont_sum_stores_transfer_id
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which don't sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_canadian
      assert_managed_dont_sum_no_internal_transfer_id
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails notifies error tracker" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_canadian
      assert_managed_dont_sum_external_notifies
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails returns the errors" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/returns_the_errors") do
      setup_perform_payment_canadian
      assert_managed_dont_sum_external_returns
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails marks the payment as failed" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_canadian
      assert_managed_dont_sum_external_marks_failed
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount creates an internal transfer and a normal transfer" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/creates_an_internal_transfer_and_a_normal_transfer") do
      setup_perform_payment_canadian
      assert_managed_sum_creates_internal_and_normal
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_canadian
      assert_managed_sum_marks_processing
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_canadian
      assert_managed_sum_stores_account_id
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_canadian
      assert_managed_sum_stores_transfer_id
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_canadian
      assert_managed_sum_stores_internal_transfer_id
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails notifies error tracker" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_canadian
      assert_managed_sum_internal_fails_notifies
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails returns the errors" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/returns_the_errors") do
      setup_perform_payment_canadian
      assert_managed_sum_internal_fails_returns
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails marks the payment as failed" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_canadian
      assert_managed_sum_internal_fails_marks_failed
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails mocked creates a reversal for the internal transfer" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/mocked/creates_a_reversal_for_the_internal_transfer") do
      setup_perform_payment_canadian
      assert_managed_mocked_creates_reversal
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails mocked creates a credit if necessary" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/mocked/creates_a_credit_if_necessary") do
      setup_perform_payment_canadian
      assert_managed_mocked_creates_credit
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe notifies error tracker" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/notifies_error_tracker") do
      setup_perform_payment_canadian
      assert_managed_hitting_notifies
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe returns the errors" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/returns_the_errors") do
      setup_perform_payment_canadian
      assert_managed_hitting_returns
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe marks the payment as failed" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/marks_the_payment_as_failed") do
      setup_perform_payment_canadian
      assert_managed_hitting_marks_failed
    end
  end

  test "perform_payment with a Canadian payout the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe the reverse amount was the same as the original internal transfer does not create a credit for the difference" do
    with_cassette("perform_payment_with_a_Canadian_payout/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/the_reverse_amount_was_the_same_as_the_original_internal_transfer/does_not_create_a_credit_for_the_difference") do
      setup_perform_payment_canadian
      assert_managed_hitting_reverse_same_no_credit
    end
  end

  # ---------------------------------------------------------------------------
  # perform_payment for a German merchant account
  # ---------------------------------------------------------------------------
  test "perform_payment for a German merchant account creates a transfer at stripe" do
    with_cassette("perform_payment_for_a_German_merchant_account/creates_a_transfer_at_stripe") do
      setup_perform_payment_german
      assert_managed_creates_transfer
    end
  end

  test "perform_payment for a German merchant account marks the payment as processing" do
    with_cassette("perform_payment_for_a_German_merchant_account/marks_the_payment_as_processing") do
      setup_perform_payment_german
      assert_managed_marks_processing
    end
  end

  test "perform_payment for a German merchant account stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_German_merchant_account/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_german
      assert_managed_stores_account_id
    end
  end

  test "perform_payment for a German merchant account stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_German_merchant_account/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_german
      assert_managed_stores_transfer_id
    end
  end

  test "perform_payment for a German merchant account does not store an internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_German_merchant_account/does_not_store_an_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_german
      assert_managed_no_internal_transfer_id
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which don't sum to a positive amount creates a normal transfer" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/creates_a_normal_transfer") do
      setup_perform_payment_german
      assert_managed_dont_sum_creates_normal
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which don't sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_german
      assert_managed_dont_sum_marks_processing
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_german
      assert_managed_dont_sum_stores_account_id
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_german
      assert_managed_dont_sum_stores_transfer_id
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which don't sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_german
      assert_managed_dont_sum_no_internal_transfer_id
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails notifies error tracker" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_german
      assert_managed_dont_sum_external_notifies
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails returns the errors" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/returns_the_errors") do
      setup_perform_payment_german
      assert_managed_dont_sum_external_returns
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails marks the payment as failed" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_german
      assert_managed_dont_sum_external_marks_failed
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount creates an internal transfer and a normal transfer" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/creates_an_internal_transfer_and_a_normal_transfer") do
      setup_perform_payment_german
      assert_managed_sum_creates_internal_and_normal
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_german
      assert_managed_sum_marks_processing
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_german
      assert_managed_sum_stores_account_id
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_german
      assert_managed_sum_stores_transfer_id
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_german
      assert_managed_sum_stores_internal_transfer_id
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails notifies error tracker" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_german
      assert_managed_sum_internal_fails_notifies
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails returns the errors" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/returns_the_errors") do
      setup_perform_payment_german
      assert_managed_sum_internal_fails_returns
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails marks the payment as failed" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_german
      assert_managed_sum_internal_fails_marks_failed
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails mocked creates a reversal for the internal transfer" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/mocked/creates_a_reversal_for_the_internal_transfer") do
      setup_perform_payment_german
      assert_managed_mocked_creates_reversal
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails mocked creates a credit if necessary" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/mocked/creates_a_credit_if_necessary") do
      setup_perform_payment_german
      assert_managed_mocked_creates_credit
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe notifies error tracker" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/notifies_error_tracker") do
      setup_perform_payment_german
      assert_managed_hitting_notifies
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe returns the errors" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/returns_the_errors") do
      setup_perform_payment_german
      assert_managed_hitting_returns
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe marks the payment as failed" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/marks_the_payment_as_failed") do
      setup_perform_payment_german
      assert_managed_hitting_marks_failed
    end
  end

  test "perform_payment for a German merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe the reverse amount was different for the managed account creates a credit for the difference" do
    with_cassette("perform_payment_for_a_German_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/the_reverse_amount_was_different_for_the_managed_account/creates_a_credit_for_the_difference") do
      setup_perform_payment_german
      assert_managed_hitting_reverse_different_creates_credit
    end
  end

  # ---------------------------------------------------------------------------
  # perform_payment for a Singaporean merchant account
  # ---------------------------------------------------------------------------
  test "perform_payment for a Singaporean merchant account creates a transfer at stripe" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/creates_a_transfer_at_stripe") do
      setup_perform_payment_singaporean
      assert_managed_creates_transfer
    end
  end

  test "perform_payment for a Singaporean merchant account marks the payment as processing" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/marks_the_payment_as_processing") do
      setup_perform_payment_singaporean
      assert_managed_marks_processing
    end
  end

  test "perform_payment for a Singaporean merchant account stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_singaporean
      assert_managed_stores_account_id
    end
  end

  test "perform_payment for a Singaporean merchant account stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_singaporean
      assert_managed_stores_transfer_id
    end
  end

  test "perform_payment for a Singaporean merchant account does not store an internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/does_not_store_an_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_singaporean
      assert_managed_no_internal_transfer_id
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount creates a normal transfer" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/creates_a_normal_transfer") do
      setup_perform_payment_singaporean
      assert_managed_dont_sum_creates_normal
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_singaporean
      assert_managed_dont_sum_marks_processing
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_singaporean
      assert_managed_dont_sum_stores_account_id
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_singaporean
      assert_managed_dont_sum_stores_transfer_id
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_singaporean
      assert_managed_dont_sum_no_internal_transfer_id
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails notifies error tracker" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_singaporean
      assert_managed_dont_sum_external_notifies
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails returns the errors" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/returns_the_errors") do
      setup_perform_payment_singaporean
      assert_managed_dont_sum_external_returns
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails marks the payment as failed" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_singaporean
      assert_managed_dont_sum_external_marks_failed
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount creates an internal transfer and a normal transfer" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/creates_an_internal_transfer_and_a_normal_transfer") do
      setup_perform_payment_singaporean
      assert_managed_sum_creates_internal_and_normal
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_singaporean
      assert_managed_sum_marks_processing
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_singaporean
      assert_managed_sum_stores_account_id
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_singaporean
      assert_managed_sum_stores_transfer_id
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_singaporean
      assert_managed_sum_stores_internal_transfer_id
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails notifies error tracker" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_singaporean
      assert_managed_sum_internal_fails_notifies
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails returns the errors" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/returns_the_errors") do
      setup_perform_payment_singaporean
      assert_managed_sum_internal_fails_returns
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails marks the payment as failed" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_singaporean
      assert_managed_sum_internal_fails_marks_failed
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails mocked creates a reversal for the internal transfer" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/mocked/creates_a_reversal_for_the_internal_transfer") do
      setup_perform_payment_singaporean
      assert_managed_mocked_creates_reversal
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails mocked creates a credit if necessary" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/mocked/creates_a_credit_if_necessary") do
      setup_perform_payment_singaporean
      assert_managed_mocked_creates_credit
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe notifies error tracker" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/notifies_error_tracker") do
      setup_perform_payment_singaporean
      assert_managed_hitting_notifies
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe returns the errors" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/returns_the_errors") do
      setup_perform_payment_singaporean
      assert_managed_hitting_returns
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe marks the payment as failed" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/marks_the_payment_as_failed") do
      setup_perform_payment_singaporean
      assert_managed_hitting_marks_failed
    end
  end

  test "perform_payment for a Singaporean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe the reverse amount was different for the managed account creates a credit for the difference" do
    with_cassette("perform_payment_for_a_Singaporean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/the_reverse_amount_was_different_for_the_managed_account/creates_a_credit_for_the_difference") do
      setup_perform_payment_singaporean
      assert_managed_hitting_reverse_different_creates_credit
    end
  end

  # ---------------------------------------------------------------------------
  # perform_payment for a Korean merchant account
  # ---------------------------------------------------------------------------
  test "perform_payment for a Korean merchant account creates a transfer at stripe" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/creates_a_transfer_at_stripe") do
      setup_perform_payment_korean
      assert_managed_creates_transfer_korean
    end
  end

  test "perform_payment for a Korean merchant account marks the payment as processing" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/marks_the_payment_as_processing") do
      setup_perform_payment_korean
      assert_managed_marks_processing
    end
  end

  test "perform_payment for a Korean merchant account stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_korean
      assert_managed_stores_account_id
    end
  end

  test "perform_payment for a Korean merchant account stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_korean
      assert_managed_stores_transfer_id
    end
  end

  test "perform_payment for a Korean merchant account does not store an internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/does_not_store_an_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_korean
      assert_managed_no_internal_transfer_id
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount creates a normal transfer" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/creates_a_normal_transfer") do
      setup_perform_payment_korean
      assert_managed_dont_sum_creates_normal
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_korean
      assert_managed_dont_sum_marks_processing
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_korean
      assert_managed_dont_sum_stores_account_id
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_korean
      assert_managed_dont_sum_stores_transfer_id
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_korean
      assert_managed_dont_sum_no_internal_transfer_id
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails notifies error tracker" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_korean
      assert_managed_dont_sum_external_notifies
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails returns the errors" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/returns_the_errors") do
      setup_perform_payment_korean
      assert_managed_dont_sum_external_returns
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which don't sum to a positive amount the external transfer fails marks the payment as failed" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_don_t_sum_to_a_positive_amount/the_external_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_korean
      assert_managed_dont_sum_external_marks_failed
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount creates an internal transfer and a normal transfer" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/creates_an_internal_transfer_and_a_normal_transfer") do
      setup_perform_payment_korean
      assert_managed_sum_creates_internal_and_normal
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount marks the payment as processing" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/marks_the_payment_as_processing") do
      setup_perform_payment_korean
      assert_managed_sum_marks_processing
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount stores the stripe account identifier of the account the transfer was created on, on the payment" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_account_identifier_of_the_account_the_transfer_was_created_on_on_the_payment") do
      setup_perform_payment_korean
      assert_managed_sum_stores_account_id
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount stores the stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_korean
      assert_managed_sum_stores_transfer_id
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount stores the internal stripe transfer's identifier on the payment" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/stores_the_internal_stripe_transfer_s_identifier_on_the_payment") do
      setup_perform_payment_korean
      assert_managed_sum_stores_internal_transfer_id
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails notifies error tracker" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/notifies_error_tracker") do
      setup_perform_payment_korean
      assert_managed_sum_internal_fails_notifies
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails returns the errors" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/returns_the_errors") do
      setup_perform_payment_korean
      assert_managed_sum_internal_fails_returns
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount the internal transfer fails marks the payment as failed" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_internal_transfer_fails/marks_the_payment_as_failed") do
      setup_perform_payment_korean
      assert_managed_sum_internal_fails_marks_failed
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails mocked creates a reversal for the internal transfer" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/mocked/creates_a_reversal_for_the_internal_transfer") do
      setup_perform_payment_korean
      assert_managed_mocked_creates_reversal
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails mocked creates a credit if necessary" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/mocked/creates_a_credit_if_necessary") do
      setup_perform_payment_korean
      assert_managed_mocked_creates_credit
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe notifies error tracker" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/notifies_error_tracker") do
      setup_perform_payment_korean
      assert_managed_hitting_notifies
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe returns the errors" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/returns_the_errors") do
      setup_perform_payment_korean
      assert_managed_hitting_returns
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe marks the payment as failed" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/marks_the_payment_as_failed") do
      setup_perform_payment_korean
      assert_managed_hitting_marks_failed
    end
  end

  test "perform_payment for a Korean merchant account the payment includes funds not held by stripe, which sum to a positive amount the external transfer fails hitting stripe the reverse amount was different for the managed account creates a credit for the difference" do
    with_cassette("perform_payment_for_a_Korean_merchant_account/the_payment_includes_funds_not_held_by_stripe_which_sum_to_a_positive_amount/the_external_transfer_fails/hitting_stripe/the_reverse_amount_was_different_for_the_managed_account/creates_a_credit_for_the_difference") do
      setup_perform_payment_korean
      assert_managed_hitting_reverse_different_creates_credit
    end
  end

  # ---------------------------------------------------------------------------
  # handle_stripe_event
  # ---------------------------------------------------------------------------
  test "handle_stripe_event payouts an event we do nothing with, like payout.created does not error or do anything interesting" do
    event = build_stripe_event(type: "payout.created", object: payout_event_object)
    Stripe::Payout.expects(:retrieve).never
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
  end

  test "handle_stripe_event payouts an event about a manual payout on stripe standard connect account ignores the event and does not raise an error" do
    object = { object: "payout", id: "po_automatic", automatic: false, amount: 100 }.deep_stringify_keys
    event = build_stripe_event(type: "payout.paid", object:)
    Stripe::Payout.stubs(:retrieve).with("po_automatic", anything).returns(object)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
  end

  test "handle_stripe_event payouts an event about an automatic payout to bank account ignores the event and does not raise an error" do
    object = { object: "payout", id: "po_automatic", automatic: true, amount: 100, arrival_date: 1732752000 }.deep_stringify_keys
    event = build_stripe_event(type: "payout.paid", object:)
    Stripe::Payout.stubs(:retrieve).with("po_automatic", anything).returns(object)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
  end

  test "handle_stripe_event payouts an event about an automatic bank debit made by stripe payout.paid when payout is successful adds credit equal to debited amount to creator gumroad balance" do
    with_cassette("handle_stripe_event/payouts/an_event_about_an_automatic_bank_debit_made_by_stripe/payout_paid/when_payout_is_successful/adds_credit_equal_to_debited_amount_to_creator_gumroad_balance") do
      with_sidekiq_inline do
        stripe_connect_account_id = "acct_1Mid1dS3ZeAbEknF"
        merchant_account = create_merchant_account(charge_processor_merchant_id: stripe_connect_account_id)
        stripe_event = {
          "id" => "evt_1MjvKyS3ZeAbEknFBhGaaSaO", "object" => "event", "account" => stripe_connect_account_id,
          "api_version" => Stripe.api_version, "created" => 1678413940,
          "data" => { "object" => { "id" => "po_1MjvG6S3ZeAbEknFg2elYwet", "object" => "payout", "amount" => -10000, "arrival_date" => 1678406400, "automatic" => true, "balance_transaction" => "txn_1MjvG6S3ZeAbEknFPvZRik6K", "created" => 1678413638, "currency" => "usd", "description" => "STRIPE PAYOUT", "destination" => "ba_1Mid1dS3ZeAbEknFLNPfy4rl", "failure_balance_transaction" => nil, "failure_code" => nil, "failure_message" => nil, "livemode" => false, "metadata" => {}, "method" => "standard", "original_payout" => nil, "reconciliation_status" => "in_progress", "reversed_by" => nil, "source_type" => "card", "statement_descriptor" => nil, "status" => "paid", "type" => "bank_account" } },
          "livemode" => false, "pending_webhooks" => 0, "request" => { "id" => nil, "idempotency_key" => nil }, "type" => "payout.paid"
        }
        amount_cents = -10000

        with_const(:GUMROAD_ADMIN_ID, create_user(is_team_member: true).id) do
          calls = capture_and_call_original(Credit, :create_for_bank_debit_on_stripe_account!) do
            StripePayoutProcessor.handle_stripe_event(stripe_event, stripe_connect_account_id:)
            HandleStripeAutodebitForNegativeBalance.drain
          end
          assert_equal 1, calls.size
          assert_equal({ amount_cents: amount_cents.abs, merchant_account: }, calls.first[1])

          credit = Credit.last
          assert_equal merchant_account, credit.merchant_account
          assert_equal merchant_account.user, credit.user
          assert_equal(-amount_cents, credit.amount_cents)
        end
      end
    end
  end

  # --- when event is about a payout we issued to a creator (mocked, no HTTP) ---
  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.paid payout doesn't match a payment raises an error" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    object = payout_event_object
    event = build_stripe_event(type: "payout.paid", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.paid payout partially matches a payment raises an error" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment
    object = payout_event_object(payment_external_id: "asdfasdf")
    event = build_stripe_event(type: "payout.paid", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
    assert_equal "processing", payment.reload.state
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.paid payout does match a payment marks the respective payment as complete" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment
    object = payout_event_object(payment_external_id: payment.external_id)
    event = build_stripe_event(type: "payout.paid", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    assert_equal "completed", payment.reload.state
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.paid payout does match a payment payment was already marked as failed does not change the state" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment
    payment.mark_failed!
    object = payout_event_object(payment_external_id: payment.external_id)
    event = build_stripe_event(type: "payout.paid", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    assert_equal "failed", payment.reload.state
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.canceled payout doesn't match a payment raises an error" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    object = payout_event_object
    event = build_stripe_event(type: "payout.canceled", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.canceled payout partially matches a payment raises an error" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment
    object = payout_event_object(payment_external_id: "non-existent")
    event = build_stripe_event(type: "payout.canceled", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
    assert_equal "processing", payment.reload.state
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.canceled payout matches a payment marks the respective payment as cancelled" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment
    payment.balances << create_balance(user: payment.user, state: :processing)
    object = payout_event_object(payment_external_id: payment.external_id)
    event = build_stripe_event(type: "payout.canceled", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    assert_equal "cancelled", payment.reload.state
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.canceled payout matches a payment marks the respective balances as unpaid" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment
    payment.balances << create_balance(user: payment.user, state: :processing)
    object = payout_event_object(payment_external_id: payment.external_id)
    event = build_stripe_event(type: "payout.canceled", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    assert_equal "processing", payment.balances.first.state
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    assert_equal "unpaid", payment.reload.balances.first.state
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.canceled payout matches a payment when payment not in processing state raises an error" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment
    payment.balances << create_balance(user: payment.user, state: :processing)
    payment.mark_completed!
    object = payout_event_object(payment_external_id: payment.external_id)
    event = build_stripe_event(type: "payout.canceled", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.canceled payout matches a payment when payment had an internal transfer reverses the internal transfer" do
    user = create_user
    create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment(user:, stripe_internal_transfer_id: "tr_5678")
    object = payout_event_object(payment_external_id: payment.external_id)
    event = build_stripe_event(type: "payout.canceled", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    stub_internal_transfer_reversal
    @reversal_reversals.expects(:create)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.canceled payout matches a payment when payment had an internal transfer when the reverse amount was the same as the original internal transfer does not create a credit for the difference" do
    user = create_user
    create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment(user:, stripe_internal_transfer_id: "tr_5678")
    object = payout_event_object(payment_external_id: payment.external_id)
    event = build_stripe_event(type: "payout.canceled", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    stub_internal_transfer_reversal(amount_taken_cents: 100_00)
    @reversal_reversals.stubs(:create)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    assert_nil Credit.last
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.canceled payout matches a payment when payment had an internal transfer when the reverse amount was different for the managed account creates a credit for the difference" do
    user = create_user
    create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment(user:, stripe_internal_transfer_id: "tr_5678")
    object = payout_event_object(payment_external_id: payment.external_id)
    event = build_stripe_event(type: "payout.canceled", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    stub_internal_transfer_reversal(amount_taken_cents: 105_00)
    @reversal_reversals.stubs(:create)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    credit = Credit.last
    assert_equal payment, credit.returned_payment
    assert_equal 0, credit.amount_cents
    assert_equal(-5_00, credit.balance_transaction.holding_amount_gross_cents)
    assert_equal(-5_00, credit.balance_transaction.holding_amount_net_cents)
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.canceled payout matches a payment when payment had an internal transfer when the reverse amount was different for the managed account changes the balance by the difference" do
    user = create_user
    create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment(user:, stripe_internal_transfer_id: "tr_5678")
    object = payout_event_object(payment_external_id: payment.external_id)
    event = build_stripe_event(type: "payout.canceled", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    stub_internal_transfer_reversal(amount_taken_cents: 105_00)
    @reversal_reversals.stubs(:create)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    assert_equal(-5_00, payment.user.reload.balances.unpaid.sum(:holding_amount_cents))
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.failed payout doesn't match a payment raises an error" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    object = payout_event_object(failure_code: "account_closed")
    event = build_stripe_event(type: "payout.failed", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.failed payout partially matches a payment raises an error" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment
    object = payout_event_object(payment_external_id: "asdfasdf", failure_code: "account_closed")
    event = build_stripe_event(type: "payout.failed", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
    assert_equal "processing", payment.reload.state
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.failed payout does match a payment marks the respective payment as failed" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment
    object = payout_event_object(payment_external_id: payment.external_id, failure_code: "account_closed")
    event = build_stripe_event(type: "payout.failed", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    assert_equal "failed", payment.reload.state
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.failed payout does match a payment saves the failure reason and notifies the user" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment
    object = payout_event_object(payment_external_id: payment.external_id, failure_code: "account_closed")
    event = build_stripe_event(type: "payout.failed", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    assert_enqueued_email_with(ContactingCreatorMailer, :cannot_pay, args: [payment.id], queue: "critical") do
      StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    end
    assert_equal "failed", payment.reload.state
    assert_equal "account_closed", payment.failure_reason
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.failed payout does match a payment payment was already marked as completed sets the state to returned" do
    create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment
    payment.mark_completed!
    object = payout_event_object(payment_external_id: payment.external_id, failure_code: "account_closed")
    event = build_stripe_event(type: "payout.failed", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    assert_equal "returned", payment.reload.state
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.failed payout does match a payment had an internal transfer reverses the internal transfer" do
    user = create_user
    create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment(user:, stripe_internal_transfer_id: "tr_5678")
    object = payout_event_object(payment_external_id: payment.external_id, failure_code: "account_closed")
    event = build_stripe_event(type: "payout.failed", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    stub_internal_transfer_reversal
    @reversal_reversals.expects(:create)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.failed payout does match a payment had an internal transfer the reverse amount was the same as the original internal transfer does not create a credit for the difference" do
    user = create_user
    create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment(user:, stripe_internal_transfer_id: "tr_5678")
    object = payout_event_object(payment_external_id: payment.external_id, failure_code: "account_closed")
    event = build_stripe_event(type: "payout.failed", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    stub_internal_transfer_reversal(amount_taken_cents: 100_00)
    @reversal_reversals.stubs(:create)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    assert_nil Credit.last
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.failed payout does match a payment had an internal transfer the reverse amount was different for the managed account creates a credit for the difference" do
    user = create_user
    create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment(user:, stripe_internal_transfer_id: "tr_5678")
    object = payout_event_object(payment_external_id: payment.external_id, failure_code: "account_closed")
    event = build_stripe_event(type: "payout.failed", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    stub_internal_transfer_reversal(amount_taken_cents: 105_00)
    @reversal_reversals.stubs(:create)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    credit = Credit.last
    assert_equal payment, credit.returned_payment
    assert_equal 0, credit.amount_cents
    assert_equal(-5_00, credit.balance_transaction.holding_amount_gross_cents)
    assert_equal(-5_00, credit.balance_transaction.holding_amount_net_cents)
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.failed payout does match a payment had an internal transfer the reverse amount was different for the managed account has changed the balance by the difference" do
    user = create_user
    create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment(user:, stripe_internal_transfer_id: "tr_5678")
    object = payout_event_object(payment_external_id: payment.external_id, failure_code: "account_closed")
    event = build_stripe_event(type: "payout.failed", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    stub_internal_transfer_reversal(amount_taken_cents: 105_00)
    @reversal_reversals.stubs(:create)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    assert_equal(-5_00, payment.user.reload.balances.unpaid.sum(:holding_amount_cents))
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.failed payout does match a payment had an internal transfer payment was already marked as completed sets the state to returned" do
    user = create_user
    create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment(user:, stripe_internal_transfer_id: "tr_5678")
    payment.mark_completed!
    object = payout_event_object(payment_external_id: payment.external_id, failure_code: "account_closed")
    event = build_stripe_event(type: "payout.failed", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    stub_internal_transfer_reversal
    @reversal_reversals.stubs(:create)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
    assert_equal "returned", payment.reload.state
  end

  test "handle_stripe_event payouts when event is about a payout we issued to a creator payout.failed payout does match a payment had an internal transfer payment was already marked as completed reverses the internal transfer" do
    user = create_user
    create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
    payment = create_stripe_payout_payment(user:, stripe_internal_transfer_id: "tr_5678")
    payment.mark_completed!
    object = payout_event_object(payment_external_id: payment.external_id, failure_code: "account_closed")
    event = build_stripe_event(type: "payout.failed", object:)
    Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(object)
    stub_internal_transfer_reversal
    @reversal_reversals.expects(:create)
    StripePayoutProcessor.handle_stripe_event(event, stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
  end

  # --- when event is about a reversal of a payout we issued to a creator (sidekiq inline) ---
  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.paid when payout doesn't match a payment raises an error" do
    with_sidekiq_inline do
      create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
      setup_reversal_stubs(metadata_payment_external_id: nil)
      assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.paid"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.paid when payout metadata doesn't match payment's ID raises an error" do
    with_cassette("handle_stripe_event/payouts/when_event_is_about_a_reversal_of_a_payout_we_issued_to_a_creator/payout_paid/when_payout_metadata_doesn_t_match_payment_s_ID/raises_an_error") do
      with_sidekiq_inline do
        create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
        create_stripe_payout_payment
        setup_reversal_stubs(metadata_payment_external_id: "non-existent")
        assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.paid"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
      end
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.paid when payout matches a payment when payment is in processing state sets payment's state to failed" do
    with_cassette("handle_stripe_event/payouts/when_event_is_about_a_reversal_of_a_payout_we_issued_to_a_creator/payout_paid/when_payout_matches_a_payment/when_payment_is_in_processing_state/sets_payment_s_state_to_failed") do
      with_sidekiq_inline do
        create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
        payment = reversal_matching_payment
        setup_reversal_stubs(metadata_payment_external_id: payment.external_id, reversing_paid: true)
        StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.paid"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
        HandlePayoutReversedWorker.drain
        assert_equal "failed", payment.reload.state
      end
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.paid when payout matches a payment when payment is in completed state sets payment's state to returned" do
    with_cassette("handle_stripe_event/payouts/when_event_is_about_a_reversal_of_a_payout_we_issued_to_a_creator/payout_paid/when_payout_matches_a_payment/when_payment_is_in_completed_state/sets_payment_s_state_to_returned") do
      with_sidekiq_inline do
        create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
        payment = reversal_matching_payment
        payment.update_attribute(:state, "completed")
        setup_reversal_stubs(metadata_payment_external_id: payment.external_id, reversing_paid: true)
        StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.paid"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
        HandlePayoutReversedWorker.drain
        assert_equal "returned", payment.reload.state
      end
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.paid when payout matches a payment marks payment's balances as unpaid" do
    with_cassette("handle_stripe_event/payouts/when_event_is_about_a_reversal_of_a_payout_we_issued_to_a_creator/payout_paid/when_payout_matches_a_payment/marks_payment_s_balances_as_unpaid") do
      with_sidekiq_inline do
        create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
        payment = reversal_matching_payment
        setup_reversal_stubs(metadata_payment_external_id: payment.external_id, reversing_paid: true)
        assert_equal "processing", payment.balances.first.state
        StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.paid"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
        HandlePayoutReversedWorker.drain
        assert_equal "unpaid", payment.reload.balances.first.state
      end
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.paid when payout matches a payment when payout had an internal transfer reverses the internal transfer" do
    with_cassette("handle_stripe_event/payouts/when_event_is_about_a_reversal_of_a_payout_we_issued_to_a_creator/payout_paid/when_payout_matches_a_payment/when_payout_had_an_internal_transfer/reverses_the_internal_transfer") do
      with_sidekiq_inline do
        create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
        payment = create_stripe_payout_payment(stripe_internal_transfer_id: "tr_5678")
        setup_reversal_stubs(metadata_payment_external_id: payment.external_id, reversing_paid: true)
        stub_internal_transfer_reversal
        @reversal_reversals.expects(:create)
        StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.paid"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
        HandlePayoutReversedWorker.drain
        assert_equal "reversal_payout_id", payment.reload.processor_reversing_payout_id
      end
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.canceled when payout doesn't match a payment raises an error" do
    with_sidekiq_inline do
      create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
      setup_reversal_stubs(metadata_payment_external_id: nil)
      assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.canceled"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.canceled when payout metadata doesn't match payment's ID raises an error" do
    with_cassette("handle_stripe_event/payouts/when_event_is_about_a_reversal_of_a_payout_we_issued_to_a_creator/payout_canceled/when_payout_metadata_doesn_t_match_payment_s_ID/raises_an_error") do
      with_sidekiq_inline do
        create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
        create_stripe_payout_payment
        setup_reversal_stubs(metadata_payment_external_id: "non-existent")
        assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.canceled"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
      end
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.canceled when payout matches a payment ignores the event - nothing to do, a manual reversal was canceled" do
    with_cassette("handle_stripe_event/payouts/when_event_is_about_a_reversal_of_a_payout_we_issued_to_a_creator/payout_canceled/when_payout_matches_a_payment/ignores_the_event_-_nothing_to_do_a_manual_reversal_was_canceled") do
      with_sidekiq_inline do
        create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
        payment = create_stripe_payout_payment
        setup_reversal_stubs(metadata_payment_external_id: payment.external_id)
        StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.canceled"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
      end
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.failed when payout doesn't match a payment raises an error" do
    with_sidekiq_inline do
      create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
      setup_reversal_stubs(metadata_payment_external_id: nil)
      assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.failed"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.failed when payout metadata doesn't match payment's ID raises an error" do
    with_cassette("handle_stripe_event/payouts/when_event_is_about_a_reversal_of_a_payout_we_issued_to_a_creator/payout_failed/when_payout_metadata_doesn_t_match_payment_s_ID/raises_an_error") do
      with_sidekiq_inline do
        create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
        create_stripe_payout_payment
        setup_reversal_stubs(metadata_payment_external_id: "non-existent")
        assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.failed"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
      end
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.failed when payout matches a payment when payment has not been marked as reversed before ignores the event - nothing to do, a manual reversal did not succeed" do
    with_cassette("handle_stripe_event/payouts/when_event_is_about_a_reversal_of_a_payout_we_issued_to_a_creator/payout_failed/when_payout_matches_a_payment/when_payment_has_not_been_marked_as_reversed_before/ignores_the_event_-_nothing_to_do_a_manual_reversal_did_not_succeed") do
      with_sidekiq_inline do
        create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
        payment = create_stripe_payout_payment
        setup_reversal_stubs(metadata_payment_external_id: payment.external_id)
        StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.failed"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID)
      end
    end
  end

  test "handle_stripe_event payouts when event is about a reversal of a payout we issued to a creator payout.failed when payout matches a payment when payment has been marked as reversed before notifies error tracker that a previously successful reversal has changed state to failed" do
    with_cassette("handle_stripe_event/payouts/when_event_is_about_a_reversal_of_a_payout_we_issued_to_a_creator/payout_failed/when_payout_matches_a_payment/when_payment_has_been_marked_as_reversed_before/notifies_error_tracker_that_a_previously_successful_reversal_has_changed_state_to_failed") do
      with_sidekiq_inline do
        create_merchant_account(charge_processor_merchant_id: STRIPE_CONNECT_ACCOUNT_ID)
        payment = create_stripe_payout_payment
        payment.update!(processor_reversing_payout_id: "reversal_payout_id")
        setup_reversal_stubs(metadata_payment_external_id: payment.external_id)
        e = assert_raises(RuntimeError) { StripePayoutProcessor.handle_stripe_event(reversal_event(type: "payout.failed"), stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID) }
        assert_match(/The case needs manual review/, e.message)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .instantly_payable_amount_cents_on_stripe
  # ---------------------------------------------------------------------------
  test ".instantly_payable_amount_cents_on_stripe when user has no active bank account returns 0" do
    user = create_user
    bank_account = create_ach_account(user:, stripe_bank_account_id: "ba_test")
    user.bank_accounts = [bank_account]
    user.bank_accounts = []
    assert_equal 0, StripePayoutProcessor.instantly_payable_amount_cents_on_stripe(user)
  end

  test ".instantly_payable_amount_cents_on_stripe when not eligible for instant payouts returns 0" do
    user = create_user
    bank_account = create_ach_account(user:, stripe_bank_account_id: "ba_test")
    user.bank_accounts = [bank_account]
    Stripe::Balance.stubs(:retrieve).returns(Stripe::Balance.construct_from(object: "balance"))
    assert_equal 0, StripePayoutProcessor.instantly_payable_amount_cents_on_stripe(user)
  end

  test ".instantly_payable_amount_cents_on_stripe when eligible for instant payouts returns the instant available amount" do
    user = create_user
    bank_account = create_ach_account(user:, stripe_bank_account_id: "ba_test")
    user.bank_accounts = [bank_account]
    Stripe::Balance.stubs(:retrieve).returns(
      Stripe::Balance.construct_from(object: "balance", instant_available: [{ amount: 123456, currency: "usd", net_available: [{ amount: 123456, destination: "ba_test", source_types: { card: 123456 } }] }])
    )
    assert_equal 123456, StripePayoutProcessor.instantly_payable_amount_cents_on_stripe(user)
  end

  test ".instantly_payable_amount_cents_on_stripe when eligible but bank account doesn't match returns 0" do
    user = create_user
    bank_account = create_ach_account(user:, stripe_bank_account_id: "ba_test")
    user.bank_accounts = [bank_account]
    Stripe::Balance.stubs(:retrieve).returns(
      Stripe::Balance.construct_from(object: "balance", instant_available: [{ amount: 123456, currency: "usd", net_available: [{ amount: 123456, destination: "ba_different", source_types: { card: 123456 } }] }])
    )
    assert_equal 0, StripePayoutProcessor.instantly_payable_amount_cents_on_stripe(user)
  end

  # ---------------------------------------------------------------------------
  # .perform_payment Stripe error handling
  # ---------------------------------------------------------------------------
  test ".perform_payment Stripe error handling when Stripe rejects the payout because the destination bank account has been deleted marks the payment with failure_reason BANK_ACCOUNT_NOT_FOUND_AT_STRIPE" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("The bank account ba_test_xxx has been deleted and can no longer be used.", "destination"))
    StripePayoutProcessor.perform_payment(@payment)
    assert_equal Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE, @payment.reload.failure_reason
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the destination bank account has been deleted marks the bank account deleted so subsequent runs skip until the seller re-adds it" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("The bank account ba_test_xxx has been deleted and can no longer be used.", "destination"))
    assert_changes -> { @bank_account.reload.deleted_at }, from: nil do
      StripePayoutProcessor.perform_payment(@payment)
    end
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the destination bank account has been deleted stores the Stripe error message on the payment" do
    setup_perform_payment_error_case
    message = "The bank account ba_test_xxx has been deleted and can no longer be used."
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new(message, "destination"))
    StripePayoutProcessor.perform_payment(@payment)
    assert_equal message, @payment.reload.error_message
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the destination bank account has been deleted does not notify the error tracker" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("The bank account ba_test_xxx has been deleted and can no longer be used.", "destination"))
    ErrorNotifier.expects(:notify).never
    StripePayoutProcessor.perform_payment(@payment)
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the destination bank account has been deleted adds a payout note directing the seller to re-add their bank account" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("The bank account ba_test_xxx has been deleted and can no longer be used.", "destination"))
    assert_difference -> { @user.comments.with_type_payout_note.count }, 1 do
      StripePayoutProcessor.perform_payment(@payment)
    end
    assert_includes @user.comments.with_type_payout_note.last.content, "Re-add the bank account in payout settings"
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the destination bank account has been deleted and the internal transfer reversal raises a transient Stripe error afterwards still marks the bank account deleted before the reversal runs" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("The bank account ba_test_xxx has been deleted and can no longer be used.", "destination"))
    @payment.update!(stripe_internal_transfer_id: "tr_test_xxx")
    Stripe::Transfer.stubs(:retrieve).raises(Stripe::APIConnectionError.new("connection refused"))
    assert_raises(Stripe::APIConnectionError) { StripePayoutProcessor.perform_payment(@payment) }
    assert @bank_account.reload.deleted_at.present?
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the destination bank account supports a different currency marks the payment with failure_reason DESTINATION_CURRENCY_MISMATCH" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Attempting to create a transfer of ron to a destination that supports eur.", "currency"))
    StripePayoutProcessor.perform_payment(@payment)
    assert_equal Payment::FailureReason::DESTINATION_CURRENCY_MISMATCH, @payment.reload.failure_reason
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the destination bank account supports a different currency stores the Stripe error message on the payment" do
    setup_perform_payment_error_case
    message = "Attempting to create a transfer of ron to a destination that supports eur."
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new(message, "currency"))
    StripePayoutProcessor.perform_payment(@payment)
    assert_equal message, @payment.reload.error_message
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the destination bank account supports a different currency does not notify the error tracker" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Attempting to create a transfer of ron to a destination that supports eur.", "currency"))
    ErrorNotifier.expects(:notify).never
    StripePayoutProcessor.perform_payment(@payment)
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the destination bank account supports a different currency adds a payout note describing the currency mismatch" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Attempting to create a transfer of ron to a destination that supports eur.", "currency"))
    assert_difference -> { @user.comments.with_type_payout_note.count }, 1 do
      StripePayoutProcessor.perform_payment(@payment)
    end
    assert_includes @user.comments.with_type_payout_note.last.content, "does not match any bank account configured to receive it"
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the amount is below Stripe's per-currency payout minimum marks the payment with failure_reason BELOW_STRIPE_PAYOUT_MINIMUM" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Amount must be no less than £1.00", "amount"))
    StripePayoutProcessor.perform_payment(@payment)
    assert_equal Payment::FailureReason::BELOW_STRIPE_PAYOUT_MINIMUM, @payment.reload.failure_reason
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the amount is below Stripe's per-currency payout minimum stores the Stripe error message on the payment" do
    setup_perform_payment_error_case
    message = "Amount must be no less than £1.00"
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new(message, "amount"))
    StripePayoutProcessor.perform_payment(@payment)
    assert_equal message, @payment.reload.error_message
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the amount is below Stripe's per-currency payout minimum does not notify the error tracker" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Amount must be no less than £1.00", "amount"))
    ErrorNotifier.expects(:notify).never
    StripePayoutProcessor.perform_payment(@payment)
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the amount is below Stripe's per-currency payout minimum adds a payout note explaining the balance rolls into the next payout" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Amount must be no less than £1.00", "amount"))
    assert_difference -> { @user.comments.with_type_payout_note.count }, 1 do
      StripePayoutProcessor.perform_payment(@payment)
    end
    assert_includes @user.comments.with_type_payout_note.last.content, "roll into your next payout"
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the account requires further intervention marks the payment with failure_reason STRIPE_INTERVENTION_REQUIRED" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new(intervention_required_error_message, nil))
    StripePayoutProcessor.perform_payment(@payment)
    assert_equal Payment::FailureReason::STRIPE_INTERVENTION_REQUIRED, @payment.reload.failure_reason
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the account requires further intervention does not notify the error tracker" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new(intervention_required_error_message, nil))
    ErrorNotifier.expects(:notify).never
    StripePayoutProcessor.perform_payment(@payment)
  end

  test ".perform_payment Stripe error handling when Stripe rejects the payout because the account requires further intervention adds a payout note directing the seller to resolve Stripe's outstanding requirements" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new(intervention_required_error_message, nil))
    assert_difference -> { @user.comments.with_type_payout_note.count }, 1 do
      StripePayoutProcessor.perform_payment(@payment)
    end
    assert_includes @user.comments.with_type_payout_note.last.content, "resolving the outstanding requirements"
  end

  test ".perform_payment Stripe error handling when Stripe raises an unmatched Stripe::InvalidRequestError captures the error message on the payment" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Something unexpected.", "param"))
    StripePayoutProcessor.perform_payment(@payment)
    assert_equal "Something unexpected.", @payment.reload.error_message
  end

  test ".perform_payment Stripe error handling when Stripe raises an unmatched Stripe::InvalidRequestError leaves failure_reason nil so the existing flow is unchanged" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Something unexpected.", "param"))
    StripePayoutProcessor.perform_payment(@payment)
    assert_nil @payment.reload.failure_reason
  end

  test ".perform_payment Stripe error handling when Stripe raises an unmatched Stripe::InvalidRequestError still notifies the error tracker for unmatched errors" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Something unexpected.", "param"))
    ErrorNotifier.expects(:notify)
    StripePayoutProcessor.perform_payment(@payment)
  end

  test ".perform_payment Stripe error handling when Stripe raises a generic Stripe::StripeError captures the error message on the payment" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::StripeError.new("Generic Stripe error."))
    StripePayoutProcessor.perform_payment(@payment)
    assert_equal "Generic Stripe error.", @payment.reload.error_message
  end

  test ".perform_payment Stripe error handling when Stripe raises Stripe::APIConnectionError re-raises the error and stores the class and message on the payment" do
    setup_perform_payment_error_case
    Stripe::Payout.stubs(:create).raises(Stripe::APIConnectionError.new("connection refused"))
    assert_raises(Stripe::APIConnectionError) { StripePayoutProcessor.perform_payment(@payment) }
    assert_equal "Stripe::APIConnectionError: connection refused", @payment.reload.error_message
  end

  # ---------------------------------------------------------------------------
  # .cross_border_payout?
  # ---------------------------------------------------------------------------
  test ".cross_border_payout? is true for a Gumroad-managed account in a cross-border-payouts country" do
    user = create_user
    merchant_account = create_merchant_account(user:, charge_processor_merchant_id: "acct_cbp_test")
    payment = create_payment(user:, processor: PayoutProcessorType::STRIPE, state: "processing", correlation_id: nil, stripe_connect_account_id: merchant_account.charge_processor_merchant_id)
    create_user_compliance_info(user:, country: "Thailand")
    assert_equal true, StripePayoutProcessor.cross_border_payout?(payment)
  end

  test ".cross_border_payout? is false for a country that does not require cross-border payouts" do
    user = create_user
    merchant_account = create_merchant_account(user:, charge_processor_merchant_id: "acct_cbp_test")
    payment = create_payment(user:, processor: PayoutProcessorType::STRIPE, state: "processing", correlation_id: nil, stripe_connect_account_id: merchant_account.charge_processor_merchant_id)
    create_user_compliance_info(user:, country: "United States")
    assert_equal false, StripePayoutProcessor.cross_border_payout?(payment)
  end

  test ".cross_border_payout? is false for non-Stripe payouts" do
    user = create_user
    create_merchant_account(user:, charge_processor_merchant_id: "acct_cbp_test")
    create_user_compliance_info(user:, country: "Thailand")
    paypal_payment = create_payment(user:, processor: PayoutProcessorType::PAYPAL, state: "processing")
    assert_equal false, StripePayoutProcessor.cross_border_payout?(paypal_payment)
  end

  # ===END TESTS===
  private
    def setup_perform_payment_error_case
      @user = create_user
      @bank_account = create_ach_account(user: @user, stripe_connect_account_id: "acct_test_xxx", stripe_bank_account_id: "ba_test_xxx")
      merchant_account = create_merchant_account(user: @user, charge_processor_merchant_id: "acct_test_xxx", currency: "usd")
      @payment = create_payment(user: @user, bank_account: @bank_account, processor: PayoutProcessorType::STRIPE,
                                state: "processing", amount_cents: 1_000,
                                stripe_connect_account_id: merchant_account.charge_processor_merchant_id,
                                currency: "usd", payout_period_end_date: Date.current - 1, correlation_id: nil,
                                payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    end

    # Stripe's full "requires further intervention" rejection message. Kept in a helper because
    # several tests stub Stripe with this exact wording, and the processor matches on it to decide
    # the payout failed only because the seller must resolve requirements directly with Stripe.
    def intervention_required_error_message
      "This account requires further intervention to perform certain actions. Stripe will have recently reached out to resolve this, but if you require further assistance please contact us via https://support.stripe.com/contact"
    end

    def capabilities_error
      @capabilities_error ||= Stripe::InvalidRequestError.new(
        "Your destination account needs to have at least one of the following capabilities enabled: transfers, crypto_transfers, legacy_payments",
        nil
      )
    end

    def setup_prepare_payment_cad
      user = create_user
      cad_merchant_account = create_merchant_account(user:, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::CAD, country: "CA")
      balance_1 = create_balance(user:, merchant_account: cad_merchant_account, date: Date.today - 1, currency: Currency::USD, amount_cents: 100_00, holding_currency: Currency::CAD, holding_amount_cents: 100_00)
      balance_2 = create_balance(user:, merchant_account: cad_merchant_account, date: Date.today - 2, currency: Currency::USD, amount_cents: 200_00, holding_currency: Currency::CAD, holding_amount_cents: 200_00)
      @payment = create_payment(user:, currency: nil, amount_cents: nil)
      @payment.balances << balance_1
      @payment.balances << balance_2
      StripePayoutProcessor.stubs(:get_payout_details).returns([cad_merchant_account, [], [balance_1, balance_2]])
      Stripe::Balance.stubs(:retrieve).returns(
        Stripe::Balance.construct_from(object: "balance", available: [{ amount: 300_00, currency: "cad" }], pending: [{ amount: 0, currency: "cad" }])
      )
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [balance_1, balance_2])
    end

    def setup_prepare_payment_error_handling
      @user = create_user
      @merchant_account = create_merchant_account(user: @user, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::USD, country: "US")
      @gumroad_balance = create_balance(user: @user, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), currency: Currency::USD, amount_cents: 100_00, holding_currency: Currency::USD, holding_amount_cents: 100_00, state: "processing")
      @payment = create_payment(user: @user, currency: nil, amount_cents: nil, processor: PayoutProcessorType::STRIPE)
      @payment.balances << @gumroad_balance
      StripePayoutProcessor.stubs(:get_payout_details).returns([@merchant_account, [@gumroad_balance], []])
    end

    def setup_drift
      @user = create_user
      @payment = create_payment(user: @user, currency: nil, amount_cents: nil)
      @eur_merchant_account = create_merchant_account(user: @user, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::EUR, country: "ES")
      @eur_balance = create_balance(user: @user, merchant_account: @eur_merchant_account, holding_currency: Currency::EUR, holding_amount_cents: 1_356_14)
      StripePayoutProcessor.stubs(:get_payout_details).returns([@eur_merchant_account, [], [@eur_balance]])
    end

    def stub_stripe_balance(available:, pending:, currency: "eur")
      Stripe::Balance.stubs(:retrieve).returns(
        Stripe::Balance.construct_from(object: "balance", available: [{ amount: available, currency: }], pending: [{ amount: pending, currency: }])
      )
    end

    def setup_balance_transaction_nil
      @user = create_user
      @merchant_account = create_merchant_account(user: @user, charge_processor_id: StripeChargeProcessor.charge_processor_id)
      gumroad_merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      balance_held_by_gumroad = create_balance(user: @user, merchant_account: gumroad_merchant_account, state: "processing", amount_cents: 200_00, holding_amount_cents: 200_00)
      @payment = create_payment(user: @user, currency: nil, amount_cents: nil, state: "processing")
      @payment.balances << balance_held_by_gumroad
      @user.reload

      internal_transfer = stub("id" => "tr_1234", "destination_payment" => "py_1234")
      StripeTransferInternallyToCreator.stubs(:transfer_funds_to_account).returns(internal_transfer)
    end

    def destination_payment_nil_bt
      dest = stub("id" => "py_1234")
      dest.stubs(:balance_transaction).returns(nil)
      dest
    end

    def destination_payment_with_bt
      balance_transaction = stub
      balance_transaction.stubs(:amount).returns(200_00)
      dest = stub("id" => "py_1234")
      dest.stubs(:balance_transaction).returns(balance_transaction)
      dest
    end

    def setup_currency_mismatch_gumroad_held
      @user = create_user
      @payment = create_payment(user: @user, currency: nil, amount_cents: nil)
      gumroad_merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      user_merchant_account = create_merchant_account(user: @user, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::USD)
      @vnd_balance = create_balance(user: @user, merchant_account: gumroad_merchant_account, amount_cents: 0, holding_currency: Currency::VND, holding_amount_cents: -11_727)
      @usd_balance = create_balance(user: @user, merchant_account: gumroad_merchant_account, amount_cents: 126_72, holding_currency: Currency::USD, holding_amount_cents: 126_72)
      StripePayoutProcessor.stubs(:get_payout_details).returns([user_merchant_account, [@vnd_balance, @usd_balance], []])
    end

    def setup_filter_aggregate
      @user = create_user
      @gbp_merchant_account = create_merchant_account(user: @user, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::GBP, country: "GB")
      @gumroad_merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      @gbp_stripe_balance = create_balance(user: @user, merchant_account: @gbp_merchant_account, holding_currency: Currency::GBP, holding_amount_cents: 1_212_55)
    end

    def setup_prepare_payment_korean
      @user = create_user
      bank_account = create_korea_bank_account(user: @user)
      create_merchant_account_stripe_korea(user: @user)
      bank_account.reload
      @user.reload

      balance_1 = create_balance(user: @user, date: Date.today - 1, currency: Currency::USD, amount_cents: 100_00, holding_currency: Currency::USD, holding_amount_cents: 100_00)
      balance_2 = create_balance(user: @user, date: Date.today - 2, currency: Currency::USD, amount_cents: 200_00, holding_currency: Currency::USD, holding_amount_cents: 200_00)
      @payment = create_payment(user: @user, currency: nil, amount_cents: nil)
      @payment.balances << balance_1
      @payment.balances << balance_2
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, [balance_1, balance_2])
    end

    def with_cassette(name, &block)
      VCR.use_cassette("StripePayoutProcessor/#{name}", &block)
    end

    # The RSpec suite tags the reversal cases `:sidekiq_inline`. We can't use
    # Sidekiq::Testing.inline! here — running *every* incidental job inline (ES
    # reindexes etc.) inside the fixture transaction trips Makara's
    # BlacklistedWhileInTransaction guard. Instead each test drains the one worker
    # whose effect it asserts (drain runs jobs regardless of their scheduled time),
    # so this wrapper is just a readable marker for those cases.
    def with_sidekiq_inline
      yield
    end

    STRIPE_CONNECT_ACCOUNT_ID = "acct_1234"
    STRIPE_TRANSFER_ID = "tr_1234"

    def build_stripe_event(type:, object:, id: "evt_eventid")
      { "id" => id, "created" => "1406748559", "type" => type, "data" => { "object" => object.deep_stringify_keys } }
    end

    def payout_event_object(id: STRIPE_TRANSFER_ID, payment_external_id: nil, **extra)
      obj = { object: "payout", id:, currency: "usd", type: "bank_account", automatic: false }.merge(extra)
      obj[:metadata] = { payment: payment_external_id } if payment_external_id
      obj.deep_stringify_keys
    end

    # A payment matching a Stripe payout event (same connect account + transfer id).
    def create_stripe_payout_payment(**attrs)
      create_payment(processor: PayoutProcessorType::STRIPE, state: "processing",
                     stripe_connect_account_id: STRIPE_CONNECT_ACCOUNT_ID, stripe_transfer_id: STRIPE_TRANSFER_ID,
                     processor_fee_cents: 0, **attrs)
    end

    # Doubles + Mocha stubs for a payment whose internal transfer is reversed as
    # part of handling the payout event. `amount_taken_cents` different from
    # `amount_received_cents` (both default 100_00) yields a credit for the gap.
    def stub_internal_transfer_reversal(amount_received_cents: 100_00, amount_taken_cents: 100_00)
      @reversal_reversals = mock("reversals")
      internal_transfer = mock("internal_transfer")
      internal_transfer.stubs(:reversals).returns(@reversal_reversals)
      internal_transfer.stubs(:destination).returns(STRIPE_CONNECT_ACCOUNT_ID)
      internal_transfer.stubs(:destination_payment).returns("py_1234")

      destination_payment = mock("destination_payment")
      first_refund = mock("refund")
      first_refund.stubs(:balance_transaction).returns("txn_1Ects")
      refunds = mock("refunds")
      refunds.stubs(:first).returns(first_refund)
      destination_payment.stubs(:refunds).returns(refunds)
      dp_bt = mock("destination_payment_bt")
      dp_bt.stubs(:net).returns(amount_received_cents)
      destination_payment.stubs(:balance_transaction).returns(dp_bt)

      refund_bt = mock("refund_bt")
      refund_bt.stubs(:net).returns(-1 * amount_taken_cents)

      Stripe::Transfer.expects(:retrieve).with("tr_5678").at_least_once.returns(internal_transfer)
      Stripe::Charge.expects(:retrieve).with(has_entry(:id, "py_1234"), { stripe_account: STRIPE_CONNECT_ACCOUNT_ID }).at_least_once.returns(destination_payment)
      Stripe::BalanceTransaction.expects(:retrieve).with({ id: "txn_1Ects" }, { stripe_account: STRIPE_CONNECT_ACCOUNT_ID }).at_least_once.returns(refund_bt)
    end

    # The reversal-of-a-payout event: its object references the original payout
    # via `original_payout`, which is what handle_stripe_event looks the payment
    # up by.
    def reversal_event(type:)
      object = { object: "payout", id: "reversal_payout_id", currency: "usd", failure_code: "account_closed", original_payout: STRIPE_TRANSFER_ID, automatic: false }
      build_stripe_event(type:, object:)
    end

    # Stubs the retrieves the reversal path performs: the original payout (carrying
    # the payment external id in metadata) and — when `reversing_paid` — the
    # reversing payout the HandlePayoutReversedWorker polls for a paid/available
    # status.
    def setup_reversal_stubs(metadata_payment_external_id:, reversing_paid: false)
      original = { object: "payout", id: STRIPE_TRANSFER_ID, currency: "usd", failure_code: nil, automatic: false, metadata: { payment: metadata_payment_external_id } }.deep_stringify_keys
      Stripe::Payout.stubs(:retrieve).with(STRIPE_TRANSFER_ID, anything).returns(original)
      if reversing_paid
        reversing = { object: "payout", id: "reversal_payout_id", currency: "usd", failure_code: nil, automatic: false, status: "paid", balance_transaction: { status: "available" } }.deep_stringify_keys
        Stripe::Payout.stubs(:retrieve).with(has_entry(:id, "reversal_payout_id"), anything).returns(reversing)
      end
    end

    # A processing payout payment with one processing balance, matching the
    # reversal event (used by the payout.paid reversal cases).
    def reversal_matching_payment
      payment = create_stripe_payout_payment
      payment.balances << create_balance(user: payment.user, state: :processing)
      payment
    end

    # Like capture_and_call_original but returns a fixed value instead of
    # delegating — for the non-US describes that stub Stripe::Transfer/Payout with
    # doubles and only assert the arguments passed.
    def capture_and_return(receiver, method, return_value)
      calls = []
      sc = receiver.singleton_class
      orig = :"__orig_#{method}"
      sc.send(:alias_method, orig, method)
      sc.send(:define_method, method) do |*args, **kwargs, &blk|
        calls << [args, kwargs]
        return_value
      end
      yield
      calls
    ensure
      sc.send(:alias_method, method, orig)
      sc.send(:remove_method, orig)
    end

    # A Gumroad-managed account in a non-US country: Stripe::Payout.create and
    # Stripe::Balance.retrieve are stubbed (the account creation itself is the
    # only real HTTP, replayed from the cassette). Balance is reported flush in
    # every currency so the drift check always passes.
    def setup_perform_payment_managed(currency:, currency_str:, bank_account_type:, compliance_attrs:, payment_currency: nil)
      @user = create_user
      create_tos_agreement(user: @user)
      create_user_compliance_info(user: @user, **compliance_attrs)
      @bank_account = case bank_account_type
                      when :ach_stripe_succeed then create_ach_account_stripe_succeed(user: @user)
                      when :european then create_european_bank_account(user: @user)
                      when :singaporean then create_singaporean_bank_account(user: @user)
                      when :korea then create_korea_bank_account(user: @user)
      end
      @currency_str = currency_str
      @merchant_account = create_managed_stripe_account(user: @user, currency:)
      @bank_account.reload
      @user.reload
      @payment_amount_cents = 660_00
      @balances = [
        create_balance(state: "processing", merchant_account: @merchant_account, amount_cents: 100_00, holding_currency: currency, holding_amount_cents: 110_00),
        create_balance(state: "processing", merchant_account: @merchant_account, amount_cents: 200_00, holding_currency: currency, holding_amount_cents: 220_00),
        create_balance(state: "processing", merchant_account: @merchant_account, amount_cents: 300_00, holding_currency: currency, holding_amount_cents: 330_00),
      ]
      payment_attrs = { user: @user, bank_account: @bank_account.reload, state: "processing", processor: PayoutProcessorType::STRIPE,
                        amount_cents: @payment_amount_cents, payout_period_end_date: Date.today - 1, correlation_id: nil,
                        balances: @balances, payout_type: Payouts::PAYOUT_TYPE_STANDARD }
      payment_attrs[:currency] = payment_currency if payment_currency
      @payment = create_payment(**payment_attrs)
      Stripe::Payout.stubs(:create).returns(stub("id" => "tr_1234", "arrival_date" => 1732752000))
      Stripe::Balance.stubs(:retrieve).returns(
        Stripe::Balance.construct_from(object: "balance",
                                       available: [{ amount: 1_000_000_00, currency: "cad" }, { amount: 1_000_000_00, currency: "eur" }, { amount: 1_000_000_00, currency: "sgd" }, { amount: 1_000_000_00, currency: "krw" }, { amount: 1_000_000_00, currency: "usd" }],
                                       pending: [{ amount: 0, currency: "usd" }])
      )
    end

    def setup_perform_payment_canadian
      setup_perform_payment_managed(currency: Currency::CAD, currency_str: "cad", bank_account_type: :ach_stripe_succeed,
                                    compliance_attrs: { zip_code: "M4C 1T2", state: "BC", country: "Canada" })
    end

    def setup_perform_payment_german
      setup_perform_payment_managed(currency: Currency::EUR, currency_str: "eur", bank_account_type: :european,
                                    compliance_attrs: { zip_code: "10115", country: "Germany" })
    end

    def setup_perform_payment_singaporean
      setup_perform_payment_managed(currency: Currency::SGD, currency_str: "sgd", bank_account_type: :singaporean,
                                    compliance_attrs: { zip_code: "546080", country: "Singapore", nationality: "SG" })
    end

    def setup_perform_payment_korean
      setup_perform_payment_managed(currency: Currency::KRW, currency_str: "krw", bank_account_type: :korea,
                                    compliance_attrs: { zip_code: "546080", country: "Korea, Republic of" }, payment_currency: Currency::KRW)
    end

    # Body for the managed-account "creates a transfer at stripe" example: the
    # exact payout args are asserted and a stubbed payout is returned.
    def assert_managed_creates_transfer
      Stripe::Payout.expects(:create).with(
        expected_payout_params(payment: @payment, bank_account: @bank_account, amount: @payment_amount_cents, currency: @currency_str, method: Payouts::PAYOUT_TYPE_STANDARD, balances_for_metadata: @balances),
        { stripe_account: @merchant_account.charge_processor_merchant_id }
      ).returns(stub("id" => "tr_1234", "arrival_date" => 1732752000))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      assert_empty StripePayoutProcessor.perform_payment(@payment)
    end

    # Korea stores KRW balances multiplied by 100 in the DB (currencies.yml gives
    # KRW 100 subunits) but Stripe treats KRW as a single-unit currency, so the
    # payout amount is the DB value divided by 100. This body also checks the
    # stored amount reflects the ×100 convention.
    def assert_managed_creates_transfer_korean
      Stripe::Payout.expects(:create).with(
        expected_payout_params(payment: @payment, bank_account: @bank_account, amount: @payment_amount_cents, currency: "krw", method: Payouts::PAYOUT_TYPE_STANDARD, balances_for_metadata: @balances),
        { stripe_account: @merchant_account.charge_processor_merchant_id }
      ).returns(stub("id" => "tr_1234", "arrival_date" => 1732752000))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      assert_equal @payment_amount_cents * 100, @payment.amount_cents
      assert_empty StripePayoutProcessor.perform_payment(@payment)
    end

    def assert_managed_marks_processing
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "processing", @payment.state
    end

    def assert_managed_stores_account_id
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      assert_empty StripePayoutProcessor.perform_payment(@payment)
      assert_equal @merchant_account.charge_processor_merchant_id, @payment.stripe_connect_account_id
    end

    def assert_managed_stores_transfer_id
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      assert_empty StripePayoutProcessor.perform_payment(@payment)
      assert_match(/tr_[a-zA-Z0-9]+/, @payment.stripe_transfer_id)
    end

    def assert_managed_stores_arrival_date
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      assert_empty StripePayoutProcessor.perform_payment(@payment)
      assert_equal 1732752000, @payment.arrival_date
    end

    def assert_managed_no_internal_transfer_id
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @balances)
      assert_empty StripePayoutProcessor.perform_payment(@payment)
      assert_nil @payment.stripe_internal_transfer_id
    end

    # "don't sum to a positive amount" body: the payout covers only the
    # stripe-held funds; the two negative Gumroad-held balances roll forward.
    def assert_managed_dont_sum_creates_normal
      add_gumroad_held_balances_negative
      Stripe::Payout.expects(:create).with(
        expected_payout_params(payment: @payment, bank_account: @bank_account, amount: @payment_amount_cents, currency: @currency_str, method: Payouts::PAYOUT_TYPE_STANDARD, balances_for_metadata: @payment.balances),
        { stripe_account: @merchant_account.charge_processor_merchant_id }
      ).returns(stub("id" => "tr_1234", "arrival_date" => 1732752000))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert_empty StripePayoutProcessor.perform_payment(@payment)
    end

    # "sum to a positive amount" nested before: adds positive Gumroad-held
    # balances and stubs the internal-transfer bookkeeping calls.
    def setup_managed_sum_positive
      add_gumroad_held_balances_positive
      Stripe::Payout.stubs(:create).returns(stub("id" => "tr_1234", "destination_payment" => "py_1234", "arrival_date" => 1732752000))
      Stripe::Charge.stubs(:retrieve).returns(stub("balance_transaction" => stub("amount" => 3_00)))
    end

    # Managed-account "sum to positive / creates an internal transfer and a normal
    # transfer": both Stripe calls are stubbed with doubles; the arguments each
    # receives are captured and asserted (internal transfer in USD, payout in the
    # settlement currency, amount 663_00 = holding sum plus the landed transfer).
    def assert_managed_sum_creates_internal_and_normal
      add_gumroad_held_balances_positive
      Stripe::Charge.stubs(:retrieve).returns(stub("balance_transaction" => stub("amount" => 3_00)))
      transfer_calls = capture_and_return(Stripe::Transfer, :create, stub("id" => "tr_1234", "destination_payment" => "py_1234", "arrival_date" => 1732752000)) do
        StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      end
      assert_equal 1, transfer_calls.size
      assert_hash_includes({
                             amount: @balances_held_by_gumroad.sum(&:amount_cents),
                             currency: "usd",
                             destination: @merchant_account.charge_processor_merchant_id,
                             description: "Funds held by Gumroad for Payment #{@payment.external_id}.",
                             metadata: { payment: @payment.external_id, "balances{0}" => @balances_held_by_gumroad.map(&:external_id).join(",") },
                           }, transfer_calls.first[1])

      Stripe::Payout.unstub(:create)
      payout_calls = capture_and_return(Stripe::Payout, :create, stub("id" => "tr_1235", "arrival_date" => 1732752000)) do
        @errors = StripePayoutProcessor.perform_payment(@payment)
      end
      assert_equal 1, payout_calls.size
      assert_hash_includes({
                             amount: 663_00,
                             currency: @currency_str,
                             destination: @bank_account.stripe_bank_account_id,
                             description: @payment.external_id,
                             statement_descriptor: "Gumroad",
                             method: Payouts::PAYOUT_TYPE_STANDARD,
                             metadata: { payment: @payment.external_id, "balances{0}" => @payment.balances.map(&:external_id).join(","), bank_account: @bank_account.external_id },
                           }, payout_calls.first[0][0])
      assert_empty @errors
    end

    # Managed-account "sum to positive" simple bodies (state / id storage) using
    # the fully-stubbed internal-transfer + payout doubles.
    def managed_sum_prepare_and_perform
      setup_managed_sum_positive
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
    end

    # Managed-account "external transfer fails / mocked" doubles: the payout fails
    # and the internal transfer is reversed, all without HTTP.
    def setup_managed_mocked_external_fails
      add_gumroad_held_balances_positive
      @mocked_internal_transfer = mocked_internal_transfer
      Stripe::Transfer.expects(:create).returns(@mocked_internal_transfer)
      Stripe::Charge.expects(:retrieve).returns(mocked_destination_payment)
      Stripe::Payout.expects(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      Stripe::Transfer.expects(:retrieve).with(@mocked_internal_transfer.id).returns(@mocked_internal_transfer)
    end

    def managed_dont_sum_prepare_and_perform
      add_gumroad_held_balances_negative
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
    end

    def assert_managed_dont_sum_marks_processing
      managed_dont_sum_prepare_and_perform
      assert_equal "processing", @payment.state
    end

    def assert_managed_dont_sum_stores_account_id
      managed_dont_sum_prepare_and_perform
      assert_equal @merchant_account.charge_processor_merchant_id, @payment.stripe_connect_account_id
    end

    def assert_managed_dont_sum_stores_transfer_id
      managed_dont_sum_prepare_and_perform
      assert_match(/tr_[a-zA-Z0-9]+/, @payment.stripe_transfer_id)
    end

    def assert_managed_dont_sum_no_internal_transfer_id
      managed_dont_sum_prepare_and_perform
      assert_nil @payment.stripe_internal_transfer_id
    end

    def managed_dont_sum_external_fails
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
    end

    def assert_managed_dont_sum_external_notifies
      add_gumroad_held_balances_negative
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      ErrorNotifier.expects(:notify)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
    end

    def assert_managed_dont_sum_external_returns
      managed_dont_sum_external_fails
      assert StripePayoutProcessor.perform_payment(@payment).present?
    end

    def assert_managed_dont_sum_external_marks_failed
      managed_dont_sum_external_fails
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "failed", @payment.reload.state
    end

    def assert_managed_sum_marks_processing
      managed_sum_prepare_and_perform
      assert_equal "processing", @payment.state
    end

    def assert_managed_sum_stores_account_id
      managed_sum_prepare_and_perform
      assert_equal @merchant_account.charge_processor_merchant_id, @payment.stripe_connect_account_id
    end

    def assert_managed_sum_stores_transfer_id
      managed_sum_prepare_and_perform
      assert_match(/tr_[a-zA-Z0-9]+/, @payment.stripe_transfer_id)
    end

    def assert_managed_sum_stores_internal_transfer_id
      managed_sum_prepare_and_perform
      assert_match(/tr_[a-zA-Z0-9]+/, @payment.stripe_internal_transfer_id)
    end

    def assert_managed_sum_internal_fails_notifies
      add_gumroad_held_balances_positive
      Stripe::Transfer.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      ErrorNotifier.expects(:notify)
      assert StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a).present?
    end

    def assert_managed_sum_internal_fails_returns
      add_gumroad_held_balances_positive
      Stripe::Transfer.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      assert StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a).present?
    end

    def assert_managed_sum_internal_fails_marks_failed
      add_gumroad_held_balances_positive
      Stripe::Transfer.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      assert_equal "failed", @payment.reload.state
    end

    def assert_managed_mocked_creates_reversal
      setup_managed_mocked_external_fails
      reversals = mock
      reversals.expects(:create)
      @mocked_internal_transfer.stubs(:reversals).returns(reversals)
      StripePayoutProcessor.stubs(:create_credit_for_difference_from_reversed_internal_transfer)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
    end

    def assert_managed_mocked_creates_credit
      setup_managed_mocked_external_fails
      @mocked_internal_transfer.stubs(:reversals).returns(stub("create" => nil))
      StripePayoutProcessor.expects(:create_credit_for_difference_from_reversed_internal_transfer)
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      StripePayoutProcessor.perform_payment(@payment)
    end

    # The "hitting stripe" describes run the real internal transfer's *reversal*
    # (replayed) after the payout fails. As in the RSpec parent describe, the
    # internal transfer's balance-transaction lookup during prepare is stubbed;
    # Charge.retrieve is only un-stubbed (made real) afterwards so the reversal in
    # perform replays from the cassette.
    def managed_hitting_external_fails
      add_gumroad_held_balances_positive
      Stripe::Charge.stubs(:retrieve).returns(stub("balance_transaction" => stub("amount" => 3_00)))
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
      Stripe::Charge.unstub(:retrieve)
    end

    def assert_managed_hitting_notifies
      managed_hitting_external_fails
      ErrorNotifier.expects(:notify)
      StripePayoutProcessor.perform_payment(@payment)
    end

    def assert_managed_hitting_returns
      managed_hitting_external_fails
      assert StripePayoutProcessor.perform_payment(@payment).present?
    end

    def assert_managed_hitting_marks_failed
      managed_hitting_external_fails
      StripePayoutProcessor.perform_payment(@payment)
      assert_equal "failed", @payment.reload.state
    end

    def assert_managed_hitting_reverse_same_no_credit
      managed_hitting_external_fails
      StripePayoutProcessor.perform_payment(@payment)
      assert_nil Credit.last
    end

    def assert_managed_hitting_reverse_different_creates_credit
      managed_hitting_external_fails
      StripePayoutProcessor.perform_payment(@payment)
      assert_not_nil Credit.last
    end

    # The exact params the processor passes to Stripe::Payout.create for a payout.
    def expected_payout_params(payment:, bank_account:, amount:, currency:, method:, balances_for_metadata:)
      {
        amount:,
        currency:,
        destination: bank_account.stripe_bank_account_id,
        description: payment.external_id,
        statement_descriptor: "Gumroad",
        method:,
        metadata: {
          payment: payment.external_id,
          "balances{0}" => balances_for_metadata.map(&:external_id).join(","),
          bank_account: bank_account.external_id,
        },
      }
    end

    def assert_hash_includes(expected, actual)
      expected.each { |k, v| assert_equal v, actual[k], "expected key #{k.inspect} to equal #{v.inspect}, got #{actual[k].inspect}" }
    end

    # The net amount an instant payout wires after the instant-payout fee is
    # withheld (the processor floors this).
    def instant_payout_amount(amount_cents)
      (amount_cents * 100 / (100 + StripePayoutProcessor::INSTANT_PAYOUT_FEE_PERCENT)).floor
    end

    # A Gumroad-managed Stripe account created directly (no verification-document
    # upload / charges-enabled polling), then pinned to the given settlement
    # currency — mirrors the inline `StripeMerchantAccountManager.create_account`
    # the non-US perform_payment describes use.
    def create_managed_stripe_account(user:, currency:)
      merchant_account = StripeMerchantAccountManager.create_account(user.reload, passphrase: "1234")
      merchant_account.currency = currency
      merchant_account.save!
      merchant_account
    end

    # Two Gumroad-held balances that do NOT sum to a positive amount, so no
    # internal transfer is issued (mirrors the shared nested describe).
    def add_gumroad_held_balances_negative
      @balances_held_by_gumroad = [
        create_balance(state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00),
        create_balance(state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: -5_00),
      ]
      @payment.balances += @balances_held_by_gumroad
    end

    # Two Gumroad-held balances that sum to a positive amount, triggering an
    # internal transfer to the creator's account before the payout.
    def add_gumroad_held_balances_positive
      @balances_held_by_gumroad = [
        create_balance(state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00),
        create_balance(state: "processing", merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 1_00),
      ]
      @payment.balances += @balances_held_by_gumroad
    end

    # Doubles matching the "external transfer fails (mocked)" nested describe: a
    # fake internal transfer whose reversal/credit path is exercised without HTTP.
    def mocked_internal_transfer
      stub("id" => "tr_1234", "destination_payment" => "py_1234")
    end

    def mocked_destination_payment
      balance_transaction = stub
      balance_transaction.stubs(:amount).returns(50_00)
      destination_payment = stub
      destination_payment.stubs(:balance_transaction).returns(balance_transaction)
      destination_payment
    end

    # Mirrors the "external transfer fails / hitting stripe" before block: the
    # real internal transfer goes through (replayed), then Stripe::Payout.create
    # is forced to fail so the reversal path runs against the recorded cassette.
    def hitting_stripe_external_fails
      Stripe::Payout.stubs(:create).raises(Stripe::InvalidRequestError.new("Invalid request", "amount_cents"))
      StripePayoutProcessor.prepare_payment_and_set_amount(@payment, @payment.balances.to_a)
    end

    # US Gumroad-managed account, funded via a real payment intent so the
    # subsequent Stripe::Payout.create can pull from an available balance
    # (mirrors the "perform_payment" describe's before blocks). Balance retrieval
    # is stubbed to report the funds available so the drift check passes.
    def setup_perform_payment_us(payout_type: Payouts::PAYOUT_TYPE_STANDARD)
      @user = create_user
      create_tos_agreement(user: @user)
      create_user_compliance_info(user: @user)
      @bank_account = create_ach_account_stripe_succeed(user: @user)
      @merchant_account = create_merchant_account_stripe(user: @user.reload)
      @bank_account.reload
      @user.reload
      @payment_amount_cents = 600_00
      @balances = [
        create_balance(state: "processing", merchant_account: @merchant_account, amount_cents: 100_00),
        create_balance(state: "processing", merchant_account: @merchant_account, amount_cents: 200_00),
        create_balance(state: "processing", merchant_account: @merchant_account, amount_cents: 300_00),
      ]
      @payment = create_payment(user: @user, bank_account: @bank_account.reload, state: "processing",
                                processor: PayoutProcessorType::STRIPE, amount_cents: @payment_amount_cents,
                                payout_period_end_date: Date.today - 1, correlation_id: nil,
                                balances: @balances, payout_type:)
      payment_intent = create_stripe_payment_intent(
        StripePaymentMethodHelper.success_available_balance.to_stripejs_payment_method_id,
        amount: 600_00, currency: "usd",
        transfer_data: { destination: @merchant_account.charge_processor_merchant_id })
      payment_intent.confirm
      Stripe::Charge.retrieve(id: payment_intent.latest_charge)
      Stripe::Balance.stubs(:retrieve).returns(
        Stripe::Balance.construct_from(object: "balance", available: [{ amount: 600_00, currency: "usd" }], pending: [{ amount: 0, currency: "usd" }])
      )
    end

    # Captures each call to `receiver.method` (positional args + kwargs) while
    # still delegating to the original implementation — the Minitest equivalent of
    # RSpec's `expect(...).to receive(:m).with(...).and_call_original`. Aliasing
    # the original (rather than redefining and removing) keeps methods that are
    # only inherited/extended (e.g. Stripe::Payout.create) restorable.
    def capture_and_call_original(receiver, method)
      calls = []
      sc = receiver.singleton_class
      orig = :"__orig_#{method}"
      sc.send(:alias_method, orig, method)
      sc.send(:define_method, method) do |*args, **kwargs, &blk|
        calls << [args, kwargs]
        send(orig, *args, **kwargs, &blk)
      end
      yield
      calls
    ensure
      sc.send(:alias_method, method, orig)
      sc.send(:remove_method, orig)
    end

    def setup_is_user_payable
      # sufficient balance for US USD payout
      @u1 = create_user(user_risk_state: "compliant")
      create_balance(user: @u1, amount_cents: 10_01)
      @m1 = create_merchant_account(user: @u1)
      @b1 = create_ach_account(user: @u1, stripe_bank_account_id: "ba_bankaccountid")
      create_user_compliance_info(user: @u1)

      # insufficient balance for KOR KRW payout (real Stripe account creation)
      @u2 = create_user(user_risk_state: "compliant")
      create_balance(user: @u2, amount_cents: 10_01)
      @m2 = create_merchant_account_stripe_korea(user: @u2)
      @b2 = create_korea_bank_account(user: @u2, stripe_bank_account_id: "ba_korbankaccountid")

      # balance too high for instant payout
      @u3 = create_user(user_risk_state: "compliant")
      create_balance(user: @u3, amount_cents: 10_000_01)
      @m3 = create_merchant_account(user: @u3)
      @n3 = create_ach_account(user: @u3, stripe_bank_account_id: "ba_bankaccountid")
      create_user_compliance_info(user: @u3)
    end

    def setup_stripe_connect_for_u1
      @m1.mark_deleted!
      @b1.mark_deleted!
      @u1.update_columns(user_risk_state: "compliant")
      User.any_instance.stubs(:merchant_migration_enabled?).returns(true)
      create_merchant_account_stripe_connect(user: @u1)
      @u1.reload
    end

    def setup_has_valid_payout_info
      user = create_user(user_risk_state: "compliant")
      create_merchant_account(user:)
      create_ach_account(user:, stripe_bank_account_id: "ba_bankaccountid")
      user
    end
end
