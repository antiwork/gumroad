# frozen_string_literal: true

require "spec_helper"

describe LowBalanceProbationRecovery, versioning: true do
  let(:seller) { create(:user) }
  let(:admin) { create(:admin_user) }

  def probate!(user = seller)
    user.send(:disable_refunds_and_put_on_probation!)
    user.reload
  end

  def probation_comment(user = seller)
    user.comments.where(comment_type: Comment::COMMENT_TYPE_ON_PROBATION, author_name: "LowBalanceFraudCheck").order(:id).last
  end

  def evaluate(user = seller) = described_class.new(user.reload).evaluate

  def fund!(user = seller, cents = 100_00, **attributes)
    create(:balance, user:, amount_cents: cents, **attributes)
  end

  describe "#evaluate" do
    it "restores not_reviewed when the LowBalanceFraudCheck transition replaced not_reviewed" do
      probate!
      fund!

      evaluation = evaluate
      version = seller.versions.where("JSON_CONTAINS_PATH(CAST(object_changes AS JSON), 'one', '$.user_risk_state')").order(:id).last

      expect(evaluation).to be_eligible
      expect(evaluation.target_state).to eq("not_reviewed")
      expect(evaluation.provenance).to eq(:comment_version)
      expect(evaluation.snapshot_facts).to eq(
        "user_id" => seller.id,
        "user_external_id" => seller.external_id,
        "probation_comment_id" => probation_comment.id,
        "latest_probation_comment_id" => probation_comment.id,
        "transition_version_id" => version.id,
        "prior_state" => "not_reviewed",
        "target_state" => "not_reviewed",
      )
      expect(evaluation.unpaid_balance_cents).to eq(100_00)
    end

    it "restores compliant when the transition replaced compliant, even within the same second" do
      seller.mark_compliant!(author_name: "test")
      probate!
      fund!

      evaluation = evaluate

      expect(evaluation).to be_eligible
      expect(evaluation.target_state).to eq("compliant")
      expect(evaluation.provenance).to eq(:comment_version)
    end

    it "counts only unpaid USD balances against the threshold" do
      probate!
      fund!(seller, 60_00)
      fund!(seller, 39_99)
      fund!(seller, 500_00, state: "paid")

      expect(evaluate.reason).to eq(:insufficient_balance)

      fund!(seller, 1)
      expect(evaluate).to be_eligible
    end

    it "excludes an account with an unpaid balance that is not in USD" do
      probate!
      fund!(seller, 200_00)
      fund!(seller, 10_00, currency: Currency::EUR, holding_currency: Currency::EUR)

      expect(evaluate.reason).to eq(:noncanonical_balance)
    end

    it "excludes deleted, suspended and flagged accounts" do
      probate!
      fund!
      seller.update_columns(user_risk_state: "flagged_for_fraud")
      expect(evaluate.reason).to eq(:flagged)

      seller.update_columns(user_risk_state: "on_probation")
      seller.reload.suspend_for_fraud!(author_name: "admin")
      expect(evaluate.reason).to eq(:suspended)

      seller.update_columns(deleted_at: Time.current)
      expect(evaluate.reason).to eq(:account_deleted)
    end

    it "excludes accounts never probated by LowBalanceFraudCheck" do
      seller.put_on_probation!(author_name: "admin", content: "manual")
      fund!

      expect(evaluate.reason).to eq(:no_low_balance_probation)
    end

    it "excludes an account whose probation another decision already ended" do
      probate!
      fund!
      seller.mark_compliant!(author_name: "admin", content: "reviewed")

      expect(evaluate.reason).to eq(:not_on_probation)
    end

    it "excludes a probation followed by a newer decision, even a soft-deleted one" do
      probate!
      fund!
      note = seller.comments.create!(comment_type: Comment::COMMENT_TYPE_FLAG_NOTE, author_name: "risk", content: "looked at this")
      expect(evaluate.reason).to eq(:newer_risk_decision)

      note.mark_deleted!
      expect(evaluate.reason).to eq(:newer_risk_decision)

      note.destroy!
      seller.comments.create!(comment_type: Comment::COMMENT_TYPE_ON_PROBATION, author_name: "pause_payouts_for_seller_based_on_recent_failures", content: "card testing watch")
      expect(evaluate.reason).to eq(:newer_risk_decision)
    end

    it "excludes a retracted probation comment" do
      probate!
      fund!
      probation_comment.mark_deleted!

      expect(evaluate.reason).to eq(:probation_comment_deleted)
    end

    it "reports an automatic or admin recovery of this probation as already recovered" do
      probate!
      fund!
      described_class.new(seller).recover_automatically!

      evaluation = evaluate
      expect(evaluation.reason).to eq(:already_recovered)
      expect(evaluation.recovery_comment.author_name).to eq("LowBalanceFraudCheck")
    end

    it "recognises a recovery written before the idempotency key existed" do
      probate!
      fund!
      seller.mark_not_reviewed!(author_name: "LowBalanceFraudCheck", content: "Probation removed automatically")

      expect(evaluate.reason).to eq(:already_recovered)
    end

    describe "binding the prior state to the LowBalanceFraudCheck transition" do
      it "does not lift an earlier probation that LowBalanceFraudCheck only commented on" do
        seller.mark_compliant!(author_name: "admin")
        travel 1.minute
        seller.put_on_probation!(author_name: "admin", content: "manual probation")
        travel 1.minute
        probate!
        fund!

        evaluation = evaluate
        expect(evaluation.reason).to eq(:probation_transition_not_bound)
        expect(evaluation.prior_state).to be_nil
      end

      it "does not bind across another decision even when no other version separates them" do
        seller.disable_refunds!
        seller.put_on_probation!(author_name: "admin", content: "manual probation")
        travel 1.minute
        probate!
        fund!

        expect(evaluate.reason).to eq(:probation_transition_not_bound)
      end

      def drop_create_version!(comment)
        PaperTrail::Version.where(item_type: "Comment", item_id: comment.id, event: "create").delete_all
      end

      it "does not bind across a manual probation whose comment lost its own version" do
        seller.mark_compliant!(author_name: "admin")
        seller.disable_refunds!
        seller.put_on_probation!(author_name: "admin", content: "manual probation")
        drop_create_version!(seller.comments.find_by!(author_name: "admin", comment_type: Comment::COMMENT_TYPE_ON_PROBATION))
        travel 1.minute
        probate!
        fund!

        expect(evaluate.reason).to eq(:probation_history_ambiguous)
        described_class.new(seller.reload).recover_automatically!
        expect(seller.reload).to be_on_probation
        expect(seller.refunds_disabled?).to be(true)
      end

      it "does not bind across an unversioned manual probation written in the same second" do
        freeze_time do
          seller.mark_compliant!(author_name: "admin")
          seller.disable_refunds!
          seller.put_on_probation!(author_name: "admin", content: "manual probation")
          probate!
        end
        drop_create_version!(seller.comments.find_by!(author_name: "admin", comment_type: Comment::COMMENT_TYPE_ON_PROBATION))
        fund!

        expect(evaluate.reason).to eq(:probation_history_ambiguous)
      end

      it "still binds when an unversioned decision predates the transition's second" do
        seller.mark_compliant!(author_name: "admin")
        drop_create_version!(seller.comments.find_by!(author_name: "admin", comment_type: Comment::COMMENT_TYPE_COMPLIANT))
        travel 1.minute
        probate!
        fund!

        evaluation = evaluate
        expect(evaluation).to be_eligible
        expect(evaluation.provenance).to eq(:comment_version)
        expect(evaluation.target_state).to eq("compliant")
      end

      it "does not bind a probation recorded without its own comment" do
        seller.put_on_probation!(author_name: "admin", content: "manual probation")
        seller.comments.where(comment_type: Comment::COMMENT_TYPE_ON_PROBATION).delete_all
        travel 1.minute
        seller.update!(name: "Renamed seller")
        probate!
        fund!

        expect(evaluate.reason).to eq(:probation_transition_not_bound)
      end

      it "never defaults a missing history to not_reviewed" do
        unversioned = PaperTrail.request(enabled: false) do
          create(:user).tap { probate!(_1) }
        end
        fund!(unversioned)

        expect(evaluate(unversioned).reason).to eq(:missing_probation_history)
      end

      it "excludes a probation whose state change was never recorded" do
        seller
        PaperTrail.request(enabled: false) { probate! }
        fund!

        expect(evaluate.reason).to eq(:probation_history_ambiguous)
      end

      it "excludes a history with an unreadable later version" do
        probate!
        fund!
        PaperTrail::Version.create!(item_type: "User", item_id: seller.id, event: "update", object_changes: nil)

        expect(evaluate.reason).to eq(:probation_history_ambiguous)
      end

      it "excludes a pair written further apart than one transition" do
        probate!
        fund!
        comment_version = PaperTrail::Version.find_by!(item_type: "Comment", item_id: probation_comment.id, event: "create")
        comment_version.update_columns(created_at: comment_version.created_at + 6.minutes)

        expect(evaluate.reason).to eq(:probation_history_ambiguous)
      end

      it "excludes a prior state it cannot restore" do
        seller.flag_for_fraud!(author_name: "admin")
        travel 1.minute
        probate!
        fund!

        expect(evaluate.reason).to eq(:unsupported_prior_state)
      end

      describe "a LowBalanceFraudCheck probation the check re-asserted" do
        def reassert!
          travel 3.months
          seller.reload.send(:disable_refunds_and_put_on_probation!)
        end

        it "binds the state change to the first comment of the unbroken run and keys recovery on it" do
          seller.mark_compliant!(author_name: "admin")
          travel 1.minute
          probate!
          first = probation_comment
          2.times { reassert! }
          fund!

          evaluation = evaluate
          expect(evaluation).to be_eligible
          expect(evaluation.target_state).to eq("compliant")
          expect(evaluation.probation_comment).to eq(first)
          expect(evaluation.latest_probation_comment).to eq(probation_comment)
          expect(evaluation.latest_probation_comment).not_to eq(first)

          described_class.new(seller.reload).recover_automatically!
          expect(seller.reload).to be_compliant
          expect(seller.comments.where(idempotency_key: described_class.idempotency_key(first))).to exist
          expect(evaluate.reason).to eq(:already_recovered)
        end

        it "binds a re-asserted probation whose first comment has no version, by timestamp" do
          seller.mark_compliant!(author_name: "admin")
          travel 1.minute
          probate!
          PaperTrail::Version.where(item_type: "Comment", item_id: probation_comment.id).delete_all
          reassert!
          fund!

          evaluation = evaluate
          expect(evaluation.provenance).to eq(:timestamp)
          expect(evaluation.target_state).to eq("compliant")
        end

        it "does not join the run across another decision" do
          probate!
          travel 1.month
          seller.comments.create!(comment_type: Comment::COMMENT_TYPE_FLAG_NOTE, author_name: "risk", content: "reviewed the refunds")
          reassert!
          fund!

          expect(evaluate.reason).to eq(:probation_transition_not_bound)
        end

        it "does not join the run across an admin's probation that changed nothing" do
          probate!
          travel 1.month
          seller.put_on_probation!(author_name: "admin", content: "manual review")
          reassert!
          fund!

          expect(evaluate.reason).to eq(:probation_transition_not_bound)
        end

        it "excludes the run when a re-assertion was retracted" do
          probate!
          reassert!
          fund!
          probation_comment.mark_deleted!

          expect(evaluate.reason).to eq(:probation_comment_deleted)
        end
      end

      context "when the probation comment has no version of its own" do
        def drop_probation_comment_version!
          PaperTrail::Version.where(item_type: "Comment", item_id: probation_comment.id).delete_all
        end

        it "binds by timestamp when no other decision shares the transition's second" do
          seller.mark_compliant!(author_name: "admin")
          travel 1.minute
          probate!
          drop_probation_comment_version!
          fund!

          evaluation = evaluate
          expect(evaluation).to be_eligible
          expect(evaluation.provenance).to eq(:timestamp)
          expect(evaluation.target_state).to eq("compliant")
        end

        it "excludes the pair when another decision falls in the transition's second" do
          freeze_time do
            seller.mark_compliant!(author_name: "admin")
            probate!
          end
          drop_probation_comment_version!
          fund!

          expect(evaluate.reason).to eq(:probation_history_ambiguous)
        end

        it "excludes a LowBalanceFraudCheck comment on an earlier probation" do
          seller.put_on_probation!(author_name: "admin", content: "manual probation")
          travel 1.minute
          probate!
          drop_probation_comment_version!
          fund!

          expect(evaluate.reason).to eq(:probation_history_ambiguous)
        end
      end
    end
  end

  describe "#recover_automatically!" do
    it "restores compliant with the refund and Stripe-lift callbacks of a compliant transition" do
      seller.mark_compliant!(author_name: "admin")
      probate!
      fund!
      expect(seller.refunds_disabled?).to be(true)

      expect { described_class.new(seller).recover_automatically! }
        .to change { LiftPlatformStripePauseJob.jobs.size }.by(1)

      seller.reload
      expect(seller).to be_compliant
      expect(seller.refunds_disabled?).to be(false)
      comment = seller.comments.find_by!(idempotency_key: described_class.idempotency_key(probation_comment))
      expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_COMPLIANT)
      expect(comment.author_name).to eq("LowBalanceFraudCheck")
      expect(comment.content).to start_with("Probation removed automatically on")
      expect(LiftPlatformStripePauseJob.jobs.last["args"]).to eq([seller.id])
    end

    it "restores not_reviewed without touching refunds or Stripe" do
      probate!
      fund!

      expect { described_class.new(seller).recover_automatically! }
        .not_to change { LiftPlatformStripePauseJob.jobs.size }

      seller.reload
      expect(seller).to be_not_reviewed
      expect(seller.refunds_disabled?).to be(true)
    end

    it "writes nothing on a second run" do
      probate!
      fund!
      described_class.new(seller).recover_automatically!

      expect { described_class.new(seller.reload).recover_automatically! }
        .not_to change { seller.comments.count }
    end

    def locking_reads(&block)
      sql = []
      ActiveSupport::Notifications.subscribed(->(*, payload) { sql << payload[:sql] if payload[:sql].match?(/FOR (UPDATE|SHARE)/) }, "sql.active_record", &block)
      sql
    end

    it "turns away history it cannot bind with a warning, without locks or notifications" do
      seller.put_on_probation!(author_name: "admin", content: "manual probation")
      travel 1.minute
      probate!
      fund!
      output = StringIO.new
      warnings = ActiveSupport::Logger.new(output).tap { _1.level = Logger::WARN }
      warnings.formatter = ->(severity, _time, _progname, message) { "#{severity} #{message}\n" }
      Rails.logger.broadcast_to(warnings)
      allow(ErrorNotifier).to receive(:notify)

      locks = locking_reads { 3.times { described_class.new(seller.reload).recover_automatically! } }

      Rails.logger.stop_broadcasting_to(warnings)
      expect(seller.reload).to be_on_probation
      expect(locks).to eq([])
      expect(ErrorNotifier).not_to have_received(:notify)
      expect(output.string.lines).to eq(["WARN LowBalanceFraudCheck recovery skipped: probation_transition_not_bound (user_id=#{seller.id})\n"] * 3)
      expect(output.string).not_to include(seller.email)
    end

    it "still decides an eligible account under the row locks" do
      probate!
      fund!

      locks = locking_reads { described_class.new(seller.reload).recover_automatically! }

      expect(seller.reload).to be_not_reviewed
      expect(locks.first).to match(/FROM `users`.*FOR UPDATE/)
      expect(locks.grep(/FROM `balances`.*FOR SHARE/)).to be_present
      expect(locks.grep(/FROM `comments`.*FOR SHARE/)).to be_present
    end
  end

  describe "#recover_for_admin!" do
    def expected_facts(user = seller) = described_class.new(user.reload).evaluate.snapshot_facts

    def recover(expected: expected_facts, user: seller)
      described_class.new(user.reload).recover_for_admin!(actor: admin, request_id: "req-123", expected:)
    end

    it "restores compliant as the admin and reads the committed result back" do
      seller.mark_compliant!(author_name: "admin")
      probate!
      fund!

      outcome = nil
      expect { outcome = recover }
        .to change { LiftPlatformStripePauseJob.jobs.size }.by(1)
        .and not_change { UpdateSellerRefundEligibilityJob.jobs.size }

      expect(outcome.status).to eq(:recovered)
      comment = seller.comments.find_by!(idempotency_key: described_class.idempotency_key(probation_comment))
      expect(outcome.readback).to eq(
        user_risk_state: "compliant",
        refunds_disabled: false,
        recovery_comment_id: comment.id,
        recovery_comment_type: "compliant",
        recovery_comment_author_id: admin.id,
      )
      expect(comment.content).to include("by #{admin.name_or_username}", "admin API request req-123")
    end

    it "restores not_reviewed and leaves refunds disabled" do
      probate!
      fund!

      outcome = recover

      expect(outcome.status).to eq(:recovered)
      expect(outcome.readback).to include(user_risk_state: "not_reviewed", refunds_disabled: true)
    end

    it "refuses facts that changed after the review" do
      probate!
      fund!

      outcome = recover(expected: expected_facts.merge("prior_state" => "compliant", "target_state" => "compliant"))

      expect(outcome.status).to eq(:stale_snapshot)
      expect(seller.reload).to be_on_probation
    end

    it "skips an account that no longer qualifies" do
      probate!
      balance = fund!
      expected = expected_facts
      balance.update!(amount_cents: 99_99)

      outcome = recover(expected:)

      expect(outcome.status).to eq(:skipped)
      expect(outcome.reason).to eq(:insufficient_balance)
      expect(seller.reload).to be_on_probation
    end

    it "answers a repeat with already_recovered and writes nothing" do
      probate!
      fund!
      expected = expected_facts
      recover(expected:)

      outcome = nil
      expect { outcome = recover(expected:) }.not_to change { seller.comments.count }
      expect(outcome.status).to eq(:already_recovered)
      expect(outcome.as_json[:recovered_by]).to eq("admin")
    end

    it "reports a rollback when the transition raises before committing" do
      seller.mark_compliant!(author_name: "admin")
      probate!
      fund!
      expected = expected_facts
      allow_any_instance_of(User).to receive(:add_user_comment).and_raise(ActiveRecord::RecordInvalid)
      lift_jobs_before = LiftPlatformStripePauseJob.jobs.size

      outcome = recover(expected:)

      expect(outcome.as_json).to include(outcome: "error", reason: "rolled_back", rolled_back: true, error_class: "ActiveRecord::RecordInvalid")
      seller.reload
      expect(seller).to be_on_probation
      expect(seller.refunds_disabled?).to be(true)
      expect(LiftPlatformStripePauseJob.jobs.size).to eq(lift_jobs_before)
    end

    it "keeps the outcome when the error notifier itself fails" do
      probate!
      fund!
      expected = expected_facts
      allow_any_instance_of(User).to receive(:add_user_comment).and_raise(ActiveRecord::RecordInvalid)
      allow(ErrorNotifier).to receive(:notify).and_raise(Timeout::Error)

      expect(recover(expected:).as_json).to include(outcome: "error", reason: "rolled_back", rolled_back: true)
    end

    context "when something fails after the transaction committed" do
      def fail_committed_state(times:)
        calls = 0
        allow_any_instance_of(described_class).to receive(:committed_state).and_wrap_original do |original, *args|
          calls += 1
          raise Redis::CannotConnectError if calls <= times

          original.call(*args)
        end
      end

      it "reports a committed recovery whose readback failed, never a rollback" do
        probate!
        fund!
        expected = expected_facts
        fail_committed_state(times: 1)

        outcome = recover(expected:)

        expect(outcome.as_json).to include(outcome: "committed_unconfirmed", reason: "readback_failed", rolled_back: false,
                                           error_class: "Redis::CannotConnectError", readback: nil)
        expect(seller.reload).to be_not_reviewed
      end

      it "reports a committed result that does not read back as expected" do
        probate!
        fund!
        expected = expected_facts
        allow_any_instance_of(described_class).to receive(:committed_state)
          .and_wrap_original { |original, *args| original.call(*args).merge(user_risk_state: "on_probation") }

        outcome = recover(expected:)

        expect(outcome.as_json).to include(outcome: "committed_unconfirmed", reason: "committed_readback_mismatch", rolled_back: false)
      end
    end
  end
end
