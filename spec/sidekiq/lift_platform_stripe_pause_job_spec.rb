# frozen_string_literal: true

require "spec_helper"

describe LiftPlatformStripePauseJob do
  let(:seller) { create(:user) }
  let!(:merchant_account) do
    create(:merchant_account, user: seller,
                              charge_processor_id: StripeChargeProcessor.charge_processor_id,
                              charge_processor_merchant_id: "acct_pauselift")
  end

  # Built as a real `Stripe::StripeObject`: it exposes `[]` but not `dig`, which a Hash stub would hide.
  def stripe_account(charges_paused: true, payouts_paused: false, disabled_reason: "platform_paused", past_due: [], transfers: "inactive")
    Stripe::StripeObject.construct_from(
      id: "acct_pauselift",
      risk_controls: { charges: { pause_requested: charges_paused }, payouts: { pause_requested: payouts_paused } },
      requirements: { disabled_reason:, past_due: },
      future_requirements: { past_due: [] },
      capabilities: { transfers: }
    )
  end

  def stub_stripe(account)
    allow(Stripe::Account).to receive(:retrieve).with("acct_pauselift").and_return(account)
    allow(Stripe::Account).to receive(:update).and_return(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "active"))
  end

  def notes
    seller.comments.with_type_note.where(author_name: described_class::AUTHOR_NAME)
  end

  before { seller.mark_compliant!(author_id: create(:admin_user).id) }

  describe "#perform" do
    it "lifts the charges pause and records the before and after state" do
      stub_stripe(stripe_account)

      described_class.new.perform(seller.id)

      expect(Stripe::Account).to have_received(:update).with("acct_pauselift", risk_controls: { charges: { pause_requested: false } })
      expect(notes.pluck(:content)).to match([
                                               a_string_starting_with("Lifting the platform Stripe pause on acct_pauselift").and(include("charges paused: true", "transfers: \"inactive\"")),
                                               a_string_starting_with("Lifted the platform Stripe pause on acct_pauselift").and(include("charges paused: false", "transfers: \"active\"")),
                                             ])
    end

    it "keeps the before state on record when Stripe's response is lost" do
      stub_stripe(stripe_account)
      allow(Stripe::Account).to receive(:update).and_raise(Stripe::APIConnectionError.new("timeout"))

      expect { described_class.new.perform(seller.id) }.to raise_error(Stripe::APIConnectionError)

      expect(notes.pluck(:content)).to match([a_string_starting_with("Lifting the platform Stripe pause").and(include("charges paused: true"))])
    end

    # Replicas are off in the test environment, so the role itself is the only observable.
    it "runs on the primary database" do
      stub_stripe(stripe_account)
      allow(ApplicationRecord).to receive(:connected_to).and_call_original

      described_class.new.perform(seller.id)

      expect(ApplicationRecord).to have_received(:connected_to).with(role: :writing)
      expect(Stripe::Account).to have_received(:update)
    end

    it "does not lift the pause when a new risk decision lands while the account is being read" do
      allow(Stripe::Account).to receive(:update)
      allow(Stripe::Account).to receive(:retrieve) do
        User.find(seller.id).flag_for_fraud!(author_name: "reviewer")
        stripe_account
      end

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:update)
      expect(notes).to be_empty
    end

    it "does nothing when the account has no platform pause" do
      stub_stripe(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "active"))

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:update)
      expect(notes).to be_empty
    end

    {
      "both charges and payouts are paused" => { payouts_paused: true },
      "the reason is a rejection" => { disabled_reason: "rejected.fraud" },
      "the reason is not platform_paused" => { disabled_reason: "requirements.past_due" },
      "requirements are past due" => { past_due: ["individual.verification.document"] },
    }.each do |description, attributes|
      it "leaves the pause and adds a note when #{description}" do
        stub_stripe(stripe_account(**attributes))

        expect { described_class.new.perform(seller.id) }.not_to raise_error

        expect(Stripe::Account).not_to have_received(:update)
        expect(notes.count).to eq(1)
        expect(notes.last.content).to start_with("Left the platform Stripe pause on acct_pauselift")
      end
    end

    it "leaves a pause on future-requirements past due" do
      account = stripe_account
      account["future_requirements"] = Stripe::StripeObject.construct_from(past_due: ["company.tax_id"])
      stub_stripe(account)

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:update)
      expect(notes.last.content).to include("past-due")
    end

    it "does not act on an account that is no longer compliant" do
      seller.update!(user_risk_state: "flagged_for_fraud")
      stub_stripe(stripe_account)

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:retrieve)
    end

    it "does not act on a closed account" do
      seller.update!(deleted_at: Time.current)
      stub_stripe(stripe_account)

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:retrieve)
    end

    it "does not touch a seller's own connected Stripe account" do
      merchant_account.update!(json_data: { "meta" => { "stripe_connect" => "true" } })
      stub_stripe(stripe_account)

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:retrieve)
    end

    it "does not touch a deleted merchant account" do
      merchant_account.mark_deleted!
      stub_stripe(stripe_account)

      described_class.new.perform(seller.id)

      expect(Stripe::Account).not_to have_received(:retrieve)
    end

    context "when Stripe applies the update but its response is lost" do
      it "records the outcome on the retry instead of leaving the lift unaudited" do
        allow(Stripe::Account).to receive(:retrieve).with("acct_pauselift").and_return(stripe_account)
        allow(Stripe::Account).to receive(:update).and_raise(Stripe::APIConnectionError.new("connection reset"))

        expect { described_class.new.perform(seller.id) }.to raise_error(Stripe::APIConnectionError)
        expect(notes.count).to eq(1)
        expect(notes.last.content).to start_with("Lifting the platform Stripe pause on acct_pauselift")

        # Stripe did apply the change, so the retry reads a cleared pause and must not update again.
        allow(Stripe::Account).to receive(:retrieve).with("acct_pauselift").and_return(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "active"))
        described_class.new.perform(seller.id)

        expect(Stripe::Account).to have_received(:update).once
        expect(notes.count).to eq(2)
        expect(notes.last.content).to start_with("Confirmed the platform Stripe pause is lifted on acct_pauselift")
        expect(notes.last.content).to include("charges paused: false")
      end

      it "retries the update without a second intent note when the pause is still set" do
        allow(Stripe::Account).to receive(:retrieve).with("acct_pauselift").and_return(stripe_account)
        allow(Stripe::Account).to receive(:update).and_raise(Stripe::APIConnectionError.new("timeout"))
        expect { described_class.new.perform(seller.id) }.to raise_error(Stripe::APIConnectionError)

        allow(Stripe::Account).to receive(:update).and_return(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "active"))
        described_class.new.perform(seller.id)

        expect(notes.map { |note| note.content.split(" on ").first }).to eq(["Lifting the platform Stripe pause", "Lifted the platform Stripe pause"])
      end

      it "closes out an unfinished lift when retries are exhausted, so a later run cannot confirm it" do
        allow(Stripe::Account).to receive(:retrieve).with("acct_pauselift").and_return(stripe_account)
        allow(Stripe::Account).to receive(:update).and_raise(Stripe::APIConnectionError.new("timeout"))
        expect { described_class.new.perform(seller.id) }.to raise_error(Stripe::APIConnectionError)

        described_class.sidekiq_retries_exhausted_block.call({ "args" => [seller.id] }, Stripe::APIConnectionError.new("timeout"))
        expect(notes.last.content).to start_with("Gave up lifting the platform Stripe pause on acct_pauselift")

        allow(Stripe::Account).to receive(:retrieve).with("acct_pauselift").and_return(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "active"))
        expect { described_class.new.perform(seller.id) }.not_to change { notes.count }
        expect(notes.pluck(:content)).not_to include(a_string_starting_with("Confirmed"))
      end

      it "stays quiet on a later run once the lift has been recorded" do
        stub_stripe(stripe_account)
        described_class.new.perform(seller.id)
        allow(Stripe::Account).to receive(:retrieve).with("acct_pauselift").and_return(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "active"))

        expect { described_class.new.perform(seller.id) }.not_to change { notes.count }
      end
    end

    it "notes a request Stripe does not recognise, so an unsupported API version is visible" do
      allow(Stripe::Account).to receive(:retrieve).with("acct_pauselift").and_return(stripe_account)
      allow(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new("Received unknown parameter: risk_controls", "risk_controls"))

      expect { described_class.new.perform(seller.id) }.not_to raise_error

      expect(notes.last.content).to include("Could not lift the platform Stripe pause on acct_pauselift: Received unknown parameter: risk_controls")
    end

    it "notes a rejected Stripe request and carries on without raising" do
      allow(Stripe::Account).to receive(:retrieve).and_raise(Stripe::InvalidRequestError.new("No such account", nil))

      expect { described_class.new.perform(seller.id) }.not_to raise_error

      expect(notes.last.content).to include("Could not lift the platform Stripe pause on acct_pauselift: No such account")
    end

    it "lets a temporary Stripe failure raise so Sidekiq retries" do
      allow(Stripe::Account).to receive(:retrieve).and_raise(Stripe::APIConnectionError.new("timeout"))

      expect { described_class.new.perform(seller.id) }.to raise_error(Stripe::APIConnectionError)
    end
  end

  describe "releasing the failed-payout hold" do
    let(:bank_account) { create(:ach_account, user: seller) }

    let(:capability_error) { "Your destination account needs to have at least one of the following capabilities enabled: transfers, legacy_payments" }

    def failed_payout(reason: Payment::FailureReason::CANNOT_PAY, created_at: 1.hour.ago, error_message: capability_error)
      payment = create(:payment, user: seller, bank_account:, processor: PayoutProcessorType::STRIPE, state: "processing",
                                 stripe_connect_account_id: "acct_pauselift", created_at:)
      payment.error_message = error_message
      payment.mark_failed!(reason)
      payment
    end

    def hold_payouts_after_failures(**options)
      Payment::MAX_CONSECUTIVE_FAILED_PAYOUTS.times { failed_payout(**options) }
      expect(seller.reload.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)
    end

    def resume_notes
      seller.comments.with_type_payouts_resumed.where(author_name: described_class::AUTHOR_NAME)
    end

    before { stub_stripe(stripe_account) }

    it "releases the hold that the platform pause caused" do
      hold_payouts_after_failures

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused?).to be(false)
      expect(resume_notes.last.content).to include("Payouts automatically resumed")
    end

    it "keeps a seller's own pause when releasing the hold" do
      hold_payouts_after_failures
      seller.update!(payouts_paused_by_user: true)

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(false)
      expect(seller.payouts_paused_by_user).to be(true)
      expect(resume_notes.last.content).to include("remain paused by the creator")
    end

    it "judges the hold by the failures at the destination that tripped it, not by other destinations' payouts" do
      other_bank_account = create(:ach_account, user: seller)
      create(:payment_completed, user: seller, bank_account: other_bank_account, created_at: 2.hours.ago)
      failed_payout(reason: Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE, created_at: 3.hours.ago)
      2.times { failed_payout }
      expect(seller.reload.payouts_paused?).to be(true)
      # Counted account-wide after the completed payout above, these would look like three cannot_pay failures.
      payment = create(:payment, user: seller, bank_account: other_bank_account, processor: PayoutProcessorType::STRIPE, state: "processing",
                                 stripe_connect_account_id: "acct_pauselift", created_at: 1.hour.ago)
      payment.error_message = capability_error
      payment.mark_failed!(Payment::FailureReason::CANNOT_PAY)

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
      expect(resume_notes).to be_empty
    end

    it "tells destinations apart by Stripe connect account as well as destination id" do
      # The clean destination comes first, so a check that merged the two would only ever look at it.
      Payment::MAX_CONSECUTIVE_FAILED_PAYOUTS.times do |i|
        payment = create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing", bank_account: nil,
                                   stripe_connect_account_id: "acct_two", stripe_payout_destination_id: "ba_shared", created_at: 2.hours.ago + i.minutes)
        payment.error_message = capability_error
        payment.mark_failed!(Payment::FailureReason::CANNOT_PAY)
      end
      Payment::MAX_CONSECUTIVE_FAILED_PAYOUTS.times do |i|
        payment = create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing", bank_account: nil,
                                   stripe_connect_account_id: "acct_one", stripe_payout_destination_id: "ba_shared", created_at: 1.hour.ago + i.minutes)
        payment.error_message = capability_error
        payment.mark_failed!(i.zero? ? Payment::FailureReason::INSUFFICIENT_FUNDS : Payment::FailureReason::CANNOT_PAY)
      end
      expect(seller.reload.payouts_paused?).to be(true)

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
      expect(resume_notes).to be_empty
    end

    it "keeps the hold when no destination reaches the threshold" do
      seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      seller.comments.create!(author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts],
                              comment_type: Comment::COMMENT_TYPE_ON_PROBATION, content: "Payouts paused automatically", created_at: 1.hour.ago)
      failed_payout

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
    end

    it "keeps the hold when a failure had another cause" do
      2.times { failed_payout }
      failed_payout(reason: Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE)
      expect(seller.reload.payouts_paused?).to be(true)

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
      expect(resume_notes).to be_empty
    end

    it "keeps the hold when a failure has no recorded reason" do
      2.times { failed_payout }
      failed_payout(reason: nil)

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
    end

    it "keeps the hold when an unaccounted payout added to it, even if older failures would qualify" do
      hold_payouts_after_failures
      seller.comments.create!(author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts],
                              comment_type: Comment::COMMENT_TYPE_ON_PROBATION, created_at: 30.minutes.ago,
                              content: "Payouts paused automatically: payout abc #{StripePayoutProcessor::UNACCOUNTED_MONEY_HOLD_MARKER} — reconcile at Stripe.")

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
      expect(resume_notes).to be_empty
    end

    it "retries later, keeping the hold, while Stripe is still bringing transfers back" do
      allow(Stripe::Account).to receive(:update).and_return(stripe_account(charges_paused: false, disabled_reason: "platform_paused", transfers: "inactive"))
      hold_payouts_after_failures

      expect { described_class.new.perform(seller.id) }.to raise_error(described_class::TransfersNotActiveYet)

      expect(seller.reload.payouts_paused_internally).to be(true)
      expect(resume_notes).to be_empty
    end

    it "releases the hold on the retry once transfers are active" do
      allow(Stripe::Account).to receive(:update).and_return(stripe_account(charges_paused: false, disabled_reason: "platform_paused", transfers: "inactive"))
      hold_payouts_after_failures
      expect { described_class.new.perform(seller.id) }.to raise_error(described_class::TransfersNotActiveYet)

      allow(Stripe::Account).to receive(:retrieve).with("acct_pauselift").and_return(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "active"))
      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused?).to be(false)
      expect(resume_notes.count).to eq(1)
    end

    it "retries later when only one of the seller's accounts has transfers back" do
      create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: "acct_second")
      allow(Stripe::Account).to receive(:retrieve).with("acct_second").and_return(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "inactive"))
      hold_payouts_after_failures

      expect { described_class.new.perform(seller.id) }.to raise_error(described_class::TransfersNotActiveYet)
      expect(seller.reload.payouts_paused_internally).to be(true)
    end

    it "does not retry for a seller with no hold to release, even if transfers are not active" do
      allow(Stripe::Account).to receive(:update).and_return(stripe_account(charges_paused: false, disabled_reason: "platform_paused", transfers: "inactive"))

      expect { described_class.new.perform(seller.id) }.not_to raise_error
    end

    it "notes the kept hold when retries run out" do
      hold_payouts_after_failures

      described_class.sidekiq_retries_exhausted_block.call({ "args" => [seller.id] }, described_class::TransfersNotActiveYet.new("Stripe has not turned transfers back on for the account."))

      expect(notes.last.content).to start_with("Kept the failed-payout hold")
    end

    it "keeps the hold when the account still has past-due requirements after the lift, since they may be the cause" do
      allow(Stripe::Account).to receive(:update).and_return(stripe_account(charges_paused: false, disabled_reason: nil, past_due: ["individual.verification.document"], transfers: "inactive"))
      hold_payouts_after_failures

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
      expect(resume_notes).to be_empty
    end

    it "keeps the hold when the cannot_pay failures were a refused bank payout, not the missing capability" do
      Payment::MAX_CONSECUTIVE_FAILED_PAYOUTS.times { failed_payout(error_message: "Cannot create payouts to this bank account") }
      expect(seller.reload.payouts_paused?).to be(true)

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
      expect(resume_notes).to be_empty
    end

    it "keeps the hold when the account still lists requirements after the lift" do
      allow(Stripe::Account).to receive(:update).and_return(stripe_account(charges_paused: false, disabled_reason: "requirements.past_due", transfers: "active"))
      hold_payouts_after_failures

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
    end

    it "keeps the hold when the failures came from an account whose pause was not lifted" do
      hold_payouts_after_failures
      Payment::MAX_CONSECUTIVE_FAILED_PAYOUTS.times do |i|
        payment = create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing", bank_account: nil,
                                   stripe_connect_account_id: "acct_other", stripe_payout_destination_id: "ba_other", created_at: 1.hour.ago + i.minutes)
        payment.error_message = capability_error
        payment.mark_failed!(Payment::FailureReason::CANNOT_PAY)
      end

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
      expect(resume_notes).to be_empty
    end

    it "keeps the hold when another of the seller's accounts is still paused" do
      create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: "acct_second")
      allow(Stripe::Account).to receive(:retrieve).with("acct_second").and_return(stripe_account(payouts_paused: true))
      hold_payouts_after_failures

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
      expect(resume_notes).to be_empty
    end

    it "keeps the hold when the lift on another of the seller's accounts was rejected by Stripe" do
      create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: "acct_second")
      allow(Stripe::Account).to receive(:retrieve).with("acct_second").and_raise(Stripe::InvalidRequestError.new("No such account", "id"))
      hold_payouts_after_failures

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
      expect(resume_notes).to be_empty
    end

    it "releases the hold once every one of the seller's accounts is clear" do
      create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: "acct_second")
      allow(Stripe::Account).to receive(:retrieve).with("acct_second").and_return(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "active"))
      hold_payouts_after_failures

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused?).to be(false)
    end

    it "keeps a payout hold an admin placed" do
      seller.update!(payouts_paused_internally: true)
      seller.comments.create!(author_name: "admin", comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED, content: "Paused by support")

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
    end

    it "keeps a chargeback-rate hold even when older failed payouts exist" do
      hold_payouts_after_failures
      seller.comments.create!(
        author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate],
        comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
        content: "Payouts paused for chargeback rate",
        created_at: 1.minute.from_now
      )

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
    end

    it "keeps a hold that began after the lift, since the pause may not have been its cause" do
      described_class.new.perform(seller.id)

      stub_stripe(stripe_account(charges_paused: false, disabled_reason: nil, transfers: "active"))
      travel_to(1.minute.from_now) { hold_payouts_after_failures }
      travel_to(2.minutes.from_now) { described_class.new.perform(seller.id) }

      expect(seller.reload.payouts_paused_internally).to be(true)
      expect(resume_notes).to be_empty
    end

    it "keeps the hold when the pause was not lifted" do
      stub_stripe(stripe_account(payouts_paused: true))
      hold_payouts_after_failures

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
    end

    it "does not release the hold of a seller who is no longer compliant" do
      hold_payouts_after_failures
      seller.update!(user_risk_state: "flagged_for_fraud")

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally).to be(true)
    end
  end

  describe "enqueueing" do
    let(:other_seller) { create(:user) }

    it "is enqueued once the compliant transition commits" do
      expect do
        other_seller.mark_compliant!(author_id: create(:admin_user).id)
      end.to change { described_class.jobs.size }.by(1)
      expect(described_class.jobs.last["args"]).to eq([other_seller.id])
    end

    it "is not enqueued when the transition rolls back" do
      expect do
        User.transaction do
          other_seller.mark_compliant!(author_id: create(:admin_user).id)
          raise ActiveRecord::Rollback
        end
      end.not_to change { described_class.jobs.size }
    end

    it "is not enqueued for other risk states" do
      expect do
        other_seller.put_on_probation!(author_id: create(:admin_user).id)
      end.not_to change { described_class.jobs.size }
    end
  end
end
