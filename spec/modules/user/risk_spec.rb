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

  describe "suspension state machine callback" do
    before { Feature.activate(:account_suspended_email) }

    it "sends suspension email when suspended for TOS violation" do
      user = create(:user)
      user.flag_for_tos_violation!(author_name: "admin", bulk: true)

      expect do
        user.suspend_for_tos_violation!(author_name: "admin")
      end.to have_enqueued_mail(ContactingCreatorMailer, :account_suspended).with(user.id)
    end

    it "sends suspension email when suspended for fraud" do
      user = create(:user)
      user.flag_for_fraud!(author_name: "admin")

      expect do
        user.suspend_for_fraud!(author_name: "admin")
      end.to have_enqueued_mail(ContactingCreatorMailer, :account_suspended).with(user.id)
    end

    it "skips the generic suspension email when called with skip_generic_suspension_email" do
      user = create(:user)
      user.flag_for_tos_violation!(author_name: "admin", bulk: true)

      expect do
        user.suspend_for_tos_violation!(author_name: "admin", skip_generic_suspension_email: true)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :account_suspended)
    end

    it "does not send the generic suspension email when the feature flag is inactive" do
      Feature.deactivate(:account_suspended_email)
      user = create(:user)
      user.flag_for_tos_violation!(author_name: "admin", bulk: true)

      expect do
        user.suspend_for_tos_violation!(author_name: "admin")
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :account_suspended)
    end
  end

  describe "#suspend_due_to_stripe_risk" do
    let(:user) { create(:user) }

    before { Feature.activate(:account_suspended_email) }

    it "sends the Stripe-risk-specific email and not the generic suspension email" do
      expect do
        user.suspend_due_to_stripe_risk
      end.to have_enqueued_mail(ContactingCreatorMailer, :suspended_due_to_stripe_risk).with(user.id).once

      another_user = create(:user)
      expect do
        another_user.suspend_due_to_stripe_risk
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :account_suspended)
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
      expect(seller.dispute_rate_stats).to eq({ settled_count: 0, disputed_count: 0, rate: nil })
    end

    it "computes the dispute count rate from settled sales, excluding reversed chargebacks" do
      create_list(:purchase, 2, link: product)
      create(:purchase, link: product, chargeback_date: Time.current)
      create(:purchase, link: product, chargeback_date: Time.current, chargeback_reversed: true)

      stats = seller.dispute_rate_stats
      expect(stats[:settled_count]).to eq(4)
      expect(stats[:disputed_count]).to eq(1)
      expect(stats[:rate]).to eq(25.0)
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

      it "allows the seller to pick a no-refunds policy again" do
        seller.clear_refund_policy_enforcement!

        refund_policy = seller.reload.refund_policy
        refund_policy.max_refund_period_in_days = 0
        expect(refund_policy.valid?).to be true
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
