# frozen_string_literal: true

require "spec_helper"

describe User::Risk do
  describe "#disable_refunds!" do
    before do
      @creator = create(:user)
    end

    it "disables refunds for the creator" do
      @creator.disable_refunds!
      expect(@creator.reload.refunds_disabled?).to eq(true)
    end
  end

  describe "clearing a suspension" do
    let(:admin) { create(:admin_user) }

    User::Risk::SUSPENDED_STATES.each do |suspended_state|
      context "when the account is #{suspended_state}" do
        let!(:user) { create(:user, user_risk_state: suspended_state) }

        it "refuses to mark the account compliant without clear_suspension" do
          expect do
            user.mark_compliant!(author_id: admin.id)
          end.to raise_error(User::Risk::SuspensionClearNotAuthorizedError, /refusing to clear #{suspended_state}/)

          expect(user.reload.user_risk_state).to eq(suspended_state)
        end

        it "marks the account compliant when clear_suspension is passed" do
          user.mark_compliant!(author_id: admin.id, clear_suspension: true)

          expect(user.reload).to be_compliant
        end

        it "refuses even when the in-memory copy still thinks the account is not suspended" do
          # This is the actual race: a lane loads the account, another lane suspends it, and
          # the first lane then writes its own verdict from the stale copy it is holding.
          stale_copy = User.find(user.id)
          stale_copy.update_column(:user_risk_state, "not_reviewed")
          User.where(id: user.id).update_all(user_risk_state: suspended_state)

          expect do
            stale_copy.mark_compliant!(author_name: "first_payout_review")
          end.to raise_error(User::Risk::SuspensionClearNotAuthorizedError)

          expect(user.reload.user_risk_state).to eq(suspended_state)
        end

        # Compliant is not the only way out of a suspension. Probation re-enables the
        # seller's links just like compliant does, and not_reviewed drops the account back
        # to its initial state, so both need the same authorization.
        it "refuses to put the account on probation without clear_suspension" do
          expect do
            user.put_on_probation!(author_id: admin.id)
          end.to raise_error(User::Risk::SuspensionClearNotAuthorizedError, /refusing to clear #{suspended_state}/)

          expect(user.reload.user_risk_state).to eq(suspended_state)
        end

        it "puts the account on probation when clear_suspension is passed" do
          user.put_on_probation!(author_id: admin.id, clear_suspension: true)

          expect(user.reload).to be_on_probation
        end

        it "refuses probation from a stale copy that predates the suspension" do
          # The reachable version of this: LowBalanceFraudCheck decides whether to probate
          # by reading `suspended?` off a copy it loaded earlier, so a suspension landing in
          # between would otherwise be probated away by a lane that never saw it.
          stale_copy = User.find(user.id)
          stale_copy.update_column(:user_risk_state, "not_reviewed")
          User.where(id: user.id).update_all(user_risk_state: suspended_state)

          expect do
            stale_copy.put_on_probation!(author_name: "low_balance_fraud_check")
          end.to raise_error(User::Risk::SuspensionClearNotAuthorizedError)

          expect(user.reload.user_risk_state).to eq(suspended_state)
        end

        it "refuses not_reviewed from a stale copy that predates the suspension" do
          # Unlike probation, `mark_not_reviewed` only transitions from on_probation, so a
          # caller whose copy already reads as suspended is refused by the state machine
          # itself. The gap is the stale copy: the machine validates against the in-memory
          # state (on_probation), so it writes not_reviewed over a row that has since been
          # suspended. That is the case this guard has to catch.
          stale_copy = User.find(user.id)
          stale_copy.update_column(:user_risk_state, "on_probation")
          User.where(id: user.id).update_all(user_risk_state: suspended_state)

          expect do
            stale_copy.mark_not_reviewed!(author_name: "low_balance_fraud_check")
          end.to raise_error(User::Risk::SuspensionClearNotAuthorizedError, /refusing to clear #{suspended_state}/)

          expect(user.reload.user_risk_state).to eq(suspended_state)
        end
      end
    end

    it "still allows a non-suspended account to be put on probation without clear_suspension" do
      # The low-balance probation lane is the main caller and passes no flag, so an
      # unsuspended account must still be probatable exactly as before.
      user = create(:user, user_risk_state: "not_reviewed")

      user.put_on_probation!(author_name: "low_balance_fraud_check")

      expect(user.reload).to be_on_probation
    end

    it "still allows a probated account to be returned to not_reviewed without clear_suspension" do
      # This is the balance-recovery path in LowBalanceFraudCheck.
      user = create(:user, user_risk_state: "on_probation")

      user.mark_not_reviewed!(author_name: "low_balance_fraud_check")

      expect(user.reload).to be_not_reviewed
    end

    it "still allows a non-suspended account to be marked compliant without clear_suspension" do
      user = create(:user, user_risk_state: "flagged_for_tos_violation")

      user.mark_compliant!(author_id: admin.id)

      expect(user.reload).to be_compliant
    end

    it "releases a sibling this cascade suspended" do
      payment_address = "shared@example.com"
      parent = create(:user, payment_address:, user_risk_state: "suspended_for_fraud")
      sibling = create(:user, payment_address:)
      sibling.suspend_for_fraud!(author_name: "suspend_sellers_other_accounts", content: "cascade")

      parent.mark_compliant!(author_id: admin.id, clear_suspension: true)

      expect(sibling.reload).to be_compliant
    end

    it "leaves a sibling suspended on its own merits alone" do
      # The suspend cascade skips already-suspended accounts, so this one never entered it.
      # Releasing it here would undo a decision nobody in this call has looked at.
      payment_address = "shared@example.com"
      parent = create(:user, payment_address:, user_risk_state: "suspended_for_fraud")
      sibling = create(:user, payment_address:)
      sibling.suspend_for_tos_violation!(author_id: admin.id, content: "piracy")

      parent.mark_compliant!(author_id: admin.id, clear_suspension: true)

      expect(sibling.reload).to be_suspended_for_tos_violation
    end

    it "leaves a sibling alone when another lane suspends it mid-cascade" do
      # Ownership of the suspension is decided inside the transition, under the row lock, not
      # when the cascade picks the sibling up. Here the sibling starts out cascade-suspended
      # (so any pick-up-time check would wave it through) and a separate piracy review
      # suspends it on its own merits before the transition runs.
      payment_address = "shared@example.com"
      parent = create(:user, payment_address:, user_risk_state: "suspended_for_fraud")
      sibling = create(:user, payment_address:)
      sibling.suspend_for_fraud!(author_name: "suspend_sellers_other_accounts", content: "cascade")

      allow_any_instance_of(User).to receive(:mark_compliant!).and_wrap_original do |original, *args|
        if original.receiver.id == sibling.id
          User.find(sibling.id).update_column(:user_risk_state, "suspended_for_tos_violation")
          Comment.create!(commentable: sibling, comment_type: Comment::COMMENT_TYPE_SUSPENDED,
                          author_name: "piracy_review", content: "Suspended for selling pirated content")
        end
        original.call(*args)
      end

      parent.mark_compliant!(author_id: admin.id, clear_suspension: true)

      expect(sibling.reload).to be_suspended_for_tos_violation
    end

    it "still releases the other siblings when one of them is refused" do
      payment_address = "shared@example.com"
      parent = create(:user, payment_address:, user_risk_state: "suspended_for_fraud")
      own_merits_sibling = create(:user, payment_address:)
      own_merits_sibling.suspend_for_tos_violation!(author_id: admin.id, content: "piracy")
      cascade_sibling = create(:user, payment_address:)
      cascade_sibling.suspend_for_fraud!(author_name: "suspend_sellers_other_accounts", content: "cascade")

      parent.mark_compliant!(author_id: admin.id, clear_suspension: true)

      expect(own_merits_sibling.reload).to be_suspended_for_tos_violation
      expect(cascade_sibling.reload).to be_compliant
    end

    it "leaves a suspension in place when the low-balance probation check runs after it" do
      # This check lifts probation once a seller's balance recovers. It knows nothing about
      # why an account might be suspended, so a suspension written while it was in flight
      # has to win.
      user = create(:user)
      allow(user).to receive(:unpaid_balance_cents).and_return(100_00)
      user.send(:disable_refunds_and_put_on_probation!)
      user.suspend_for_tos_violation!(author_name: "piracy_review")

      expect { user.check_for_high_balance_and_remove_low_balance_probation! }
        .not_to change { user.reload.user_risk_state }
      expect(user.reload).to be_suspended_for_tos_violation
    end
  end

  describe "#suspend_due_to_stripe_risk" do
    let(:user) { create(:user) }

    it "sends the Stripe-risk-specific email" do
      expect do
        user.suspend_due_to_stripe_risk
      end.to have_enqueued_mail(ContactingCreatorMailer, :suspended_due_to_stripe_risk).with(user.id).once
    end

    it "records a suspension note without the reason when disabled_reason is not provided" do
      user.suspend_due_to_stripe_risk

      note = user.comments.where(comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE).last
      expect(note.content).to eq("Suspended because of high risk reported by Stripe")
    end

    it "includes the Stripe requirements.disabled_reason in the suspension note when provided" do
      user.suspend_due_to_stripe_risk(disabled_reason: "rejected.fraud")

      note = user.comments.where(comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE).last
      expect(note.content).to eq("Suspended because of high risk reported by Stripe (Stripe requirements.disabled_reason: rejected.fraud)")
    end
  end


  describe "#suspend_sellers_other_accounts" do
    let(:transition) { double("transition", args: []) }

    context "when user has PayPal as payout processor" do
      it "calls SuspendAccountsWithPaymentAddressWorker only once for all related accounts" do
        user = create(:user, payment_address: "test@example.com")
        create(:user, payment_address: "test@example.com")

        expect do
          user.suspend_sellers_other_accounts(transition)
        end.to change(SuspendAccountsWithPaymentAddressWorker.jobs, :size).from(0).to(1)
        .and change { SuspendAccountsWithPaymentAddressWorker.jobs.last&.dig("args") }.to([user.id])

        expect do
          SuspendAccountsWithPaymentAddressWorker.perform_one
        end.to change(SuspendAccountsWithPaymentAddressWorker.jobs, :size).from(1).to(0)
      end
    end
  end

  describe "#unblock_seller_ip!" do
    let(:ip) { "203.0.113.42" }
    let(:user) { create(:user, last_sign_in_ip: ip) }

    it "does nothing when last_sign_in_ip is blank" do
      user.update_column(:last_sign_in_ip, nil)
      expect { user.unblock_seller_ip! }.not_to raise_error
    end

    it "only unblocks rows scoped to the ip_address type" do
      email_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: ip)
      ip_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: ip, expires_in: 1.hour)

      user.unblock_seller_ip!

      expect(ip_block.reload.blocked_at).to be_nil
      expect(email_block.reload.blocked_at).to be_present
    end
  end

  describe "#dispute_rate_stats" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    it "returns a nil rate when the seller has no settled sales" do
      expect(seller.dispute_rate_stats).to eq({ settled_count: 0, settled_buyers_count: 0, disputing_buyers_count: 0, rate: nil })
    end

    it "computes the dispute rate from unique buyers, excluding reversed chargebacks" do
      create_list(:purchase, 2, link: product)
      create(:purchase, link: product, chargeback_date: Time.current)
      create(:purchase, link: product, chargeback_date: Time.current, chargeback_reversed: true)

      stats = seller.dispute_rate_stats
      expect(stats[:settled_count]).to eq(4)
      expect(stats[:settled_buyers_count]).to eq(4)
      expect(stats[:disputing_buyers_count]).to eq(1)
      expect(stats[:rate]).to eq(25.0)
    end

    it "counts one buyer disputing multiple purchases (e.g. both installments of a course) once" do
      # The trigger case for #6171: one buyer disputed both installments of a single
      # course purchase and was previously counted as two disputes.
      create_list(:purchase, 2, link: product)
      create_list(:purchase, 2, link: product, email: "unhappy@example.com", chargeback_date: Time.current)

      stats = seller.dispute_rate_stats
      expect(stats[:settled_count]).to eq(4)
      expect(stats[:settled_buyers_count]).to eq(3)
      expect(stats[:disputing_buyers_count]).to eq(1)
      expect(stats[:rate]).to eq(1 * 100.0 / 3)
    end

    it "counts a buyer with multiple settled purchases once in the denominator" do
      create_list(:purchase, 3, link: product, email: "repeat@example.com")
      create(:purchase, link: product)

      stats = seller.dispute_rate_stats
      expect(stats[:settled_count]).to eq(4)
      expect(stats[:settled_buyers_count]).to eq(2)
      expect(stats[:disputing_buyers_count]).to eq(0)
      expect(stats[:rate]).to eq(0.0)
    end

    it "counts purchases with a null email as separate buyers instead of dropping them" do
      # purchases.email has no NOT NULL constraint at the database level, so legacy rows
      # can carry a null email even though model validation blocks it on normal writes.
      # COUNT(DISTINCT email) would drop such rows from both sides of the rate.
      create(:purchase, link: product)
      null_settled = create(:purchase, link: product)
      null_settled.update_column(:email, nil)
      null_disputed = create(:purchase, link: product, chargeback_date: Time.current)
      null_disputed.update_column(:email, nil)

      stats = seller.dispute_rate_stats
      expect(stats[:settled_count]).to eq(3)
      expect(stats[:settled_buyers_count]).to eq(3)
      expect(stats[:disputing_buyers_count]).to eq(1)
      expect(stats[:rate]).to eq(1 * 100.0 / 3)
    end
  end

  describe "#clear_refund_policy_enforcement!" do
    let(:seller) { create(:user) }

    context "when a refund policy is enforced" do
      before do
        seller.update!(refund_policy_enforced: true)
      end

      it "turns the flag off" do
        seller.clear_refund_policy_enforcement!

        expect(seller.reload.refund_policy_enforced?).to be(false)
      end

      it "creates an audit comment" do
        expect do
          seller.clear_refund_policy_enforcement!
        end.to change { seller.comments.count }.by(1)

        comment = seller.comments.last
        expect(comment.content).to include("Refund policy enforcement cleared")
        expect(comment.author_name).to eq("enforce_refund_policy_for_seller_based_on_dispute_rate")
      end

      it "still does not allow a no-refunds policy after enforcement is cleared" do
        seller.clear_refund_policy_enforcement!

        refund_policy = seller.reload.refund_policy
        refund_policy.max_refund_period_in_days = 0
        expect(refund_policy.valid?).to be true
        expect(refund_policy.max_refund_period_in_days).to eq(7)
      end
    end

    context "when no refund policy is enforced" do
      it "does nothing" do
        expect do
          seller.clear_refund_policy_enforcement!
        end.to_not change { seller.comments.count }
      end
    end
  end
end
