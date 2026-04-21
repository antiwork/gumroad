# frozen_string_literal: true

require "spec_helper"

describe ScheduledPayout do
  describe "validations" do
    it "is valid with valid attributes" do
      scheduled_payout = build(:scheduled_payout)
      expect(scheduled_payout).to be_valid
    end

    it "requires an action" do
      scheduled_payout = build(:scheduled_payout, action: nil)
      expect(scheduled_payout).not_to be_valid
    end

    it "requires action to be one of refund, payout, hold" do
      %w[refund payout hold].each do |action|
        scheduled_payout = build(:scheduled_payout, action: action)
        expect(scheduled_payout).to be_valid
      end

      scheduled_payout = build(:scheduled_payout, action: "invalid")
      expect(scheduled_payout).not_to be_valid
    end

    it "requires a status" do
      scheduled_payout = build(:scheduled_payout, status: nil)
      expect(scheduled_payout).not_to be_valid
    end

    it "requires status to be one of pending, executed, cancelled, flagged, held" do
      %w[pending executed cancelled flagged held].each do |status|
        scheduled_payout = build(:scheduled_payout, status: status)
        expect(scheduled_payout).to be_valid
      end

      scheduled_payout = build(:scheduled_payout, status: "invalid")
      expect(scheduled_payout).not_to be_valid
    end

    it "requires delay_days to be a non-negative integer" do
      scheduled_payout = build(:scheduled_payout, delay_days: -1)
      expect(scheduled_payout).not_to be_valid

      scheduled_payout = build(:scheduled_payout, delay_days: 0)
      expect(scheduled_payout).to be_valid
    end

    it "requires scheduled_at" do
      scheduled_payout = build(:scheduled_payout, scheduled_at: nil, delay_days: nil)
      expect(scheduled_payout).not_to be_valid
    end

    it "requires payout_amount_cents to be a non-negative integer" do
      scheduled_payout = build(:scheduled_payout, payout_amount_cents: nil)
      expect(scheduled_payout).not_to be_valid

      scheduled_payout = build(:scheduled_payout, payout_amount_cents: -1)
      expect(scheduled_payout).not_to be_valid

      scheduled_payout = build(:scheduled_payout, payout_amount_cents: 0)
      expect(scheduled_payout).to be_valid
    end

    describe "no_in_progress_scheduled_payout_for_user" do
      let(:user) { create(:user) }

      %w[pending flagged held].each do |status|
        it "is invalid when the user already has a #{status} scheduled payout" do
          create(:scheduled_payout, user: user, status: status)
          scheduled_payout = build(:scheduled_payout, user: user)

          expect(scheduled_payout).not_to be_valid
          expect(scheduled_payout.errors[:base]).to include("User already has a scheduled payout in progress")
        end
      end

      %w[executed cancelled].each do |status|
        it "is valid when the user's only existing scheduled payout is #{status}" do
          create(:scheduled_payout, user: user, status: status)
          scheduled_payout = build(:scheduled_payout, user: user)

          expect(scheduled_payout).to be_valid
        end
      end

      it "does not affect other users" do
        other_user = create(:user)
        create(:scheduled_payout, user: other_user, status: "pending")
        scheduled_payout = build(:scheduled_payout, user: user)

        expect(scheduled_payout).to be_valid
      end
    end
  end

  describe "#set_scheduled_at" do
    it "sets scheduled_at from delay_days on create when not provided" do
      freeze_time do
        scheduled_payout = create(:scheduled_payout, scheduled_at: nil, delay_days: 21)
        expect(scheduled_payout.scheduled_at).to eq(21.days.from_now)
      end
    end

    it "does not override scheduled_at if already set" do
      specific_time = 30.days.from_now
      scheduled_payout = create(:scheduled_payout, scheduled_at: specific_time, delay_days: 21)
      expect(scheduled_payout.scheduled_at).to be_within(1.second).of(specific_time)
    end
  end

  describe "scopes" do
    let!(:pending_payout) { create(:scheduled_payout, status: "pending", scheduled_at: 1.day.ago) }
    let!(:future_payout) { create(:scheduled_payout, status: "pending", scheduled_at: 1.day.from_now) }
    let!(:executed_payout) { create(:scheduled_payout, status: "executed") }
    let!(:cancelled_payout) { create(:scheduled_payout, status: "cancelled") }
    let!(:flagged_payout) { create(:scheduled_payout, status: "flagged") }
    let!(:held_payout) { create(:scheduled_payout, status: "held") }

    it "returns pending payouts" do
      expect(described_class.pending).to contain_exactly(pending_payout, future_payout)
    end

    it "returns due payouts" do
      expect(described_class.due).to contain_exactly(pending_payout)
    end

    it "returns executed payouts" do
      expect(described_class.executed).to contain_exactly(executed_payout)
    end

    it "returns cancelled payouts" do
      expect(described_class.cancelled).to contain_exactly(cancelled_payout)
    end

    it "returns flagged payouts" do
      expect(described_class.flagged).to contain_exactly(flagged_payout)
    end

    it "returns held payouts" do
      expect(described_class.held).to contain_exactly(held_payout)
    end

    it "returns in_progress payouts" do
      expect(described_class.in_progress).to contain_exactly(pending_payout, future_payout, flagged_payout, held_payout)
    end
  end

  describe "#execute!" do
    let(:user) { create(:user) }

    context "when action is refund" do
      let(:suspended_user) { create(:user, user_risk_state: "suspended_for_fraud") }
      let(:scheduled_payout) { create(:scheduled_payout, user: suspended_user, action: "refund", scheduled_at: 1.day.ago, created_by: create(:user)) }

      it "enqueues RefundUnpaidPurchasesWorker and marks as executed" do
        scheduled_payout.execute!

        expect(RefundUnpaidPurchasesWorker.jobs.size).to eq(1)
        expect(scheduled_payout.reload.status).to eq("executed")
        expect(scheduled_payout.executed_at).to be_present
      end

      it "raises if user is not suspended" do
        non_suspended_payout = create(:scheduled_payout, user: user, action: "refund", scheduled_at: 1.day.ago, created_by: create(:user))
        expect { non_suspended_payout.execute! }.to raise_error(RuntimeError, /Cannot refund: user is not suspended/)
      end
    end

    context "when action is payout" do
      let(:scheduled_payout) { create(:scheduled_payout, user: user, action: "payout", scheduled_at: 1.day.ago) }

      it "calls PayoutUsersService to create payout and marks as executed" do
        payment = instance_double(Payment, failed?: false)
        service = instance_double(PayoutUsersService, process: [payment])
        expect(PayoutUsersService).to receive(:new)
          .with(date_string: Date.yesterday.to_s, processor_type: user.current_payout_processor, user_ids: user.id)
          .and_return(service)

        scheduled_payout.execute!

        expect(scheduled_payout.reload.status).to eq("executed")
        expect(scheduled_payout.executed_at).to be_present
      end

      it "raises if payout fails" do
        payment = instance_double(Payment, failed?: true, errors: double(full_messages: ["Stripe account not found"]))
        service = instance_double(PayoutUsersService, process: [payment])
        allow(PayoutUsersService).to receive(:new)
          .with(date_string: Date.yesterday.to_s, processor_type: user.current_payout_processor, user_ids: user.id)
          .and_return(service)

        expect { scheduled_payout.execute! }.to raise_error(RuntimeError, /Payout failed/)
        expect(scheduled_payout.reload.status).to eq("pending")
      end

      it "raises if no payment is created" do
        service = instance_double(PayoutUsersService, process: [])
        allow(PayoutUsersService).to receive(:new)
          .with(date_string: Date.yesterday.to_s, processor_type: user.current_payout_processor, user_ids: user.id)
          .and_return(service)

        expect { scheduled_payout.execute! }.to raise_error(RuntimeError, /Payment was not sent/)
        expect(scheduled_payout.reload.status).to eq("pending")
      end
    end

    context "when action is payout above threshold" do
      let(:scheduled_payout) { create(:scheduled_payout, user: user, action: "payout", scheduled_at: 1.day.ago, payout_amount_cents: 150_000) }

      it "flags for review instead of executing" do
        expect(PayoutUsersService).not_to receive(:new)

        scheduled_payout.execute!

        expect(scheduled_payout.reload.status).to eq("flagged")
      end
    end

    context "when action is hold" do
      let(:scheduled_payout) { create(:scheduled_payout, user: user, action: "hold", scheduled_at: 1.day.ago) }

      it "transitions to held status" do
        scheduled_payout.execute!

        expect(scheduled_payout.reload.status).to eq("held")
      end
    end

    it "raises if already executed" do
      scheduled_payout = create(:scheduled_payout, user: user, status: "executed")
      expect { scheduled_payout.execute! }.to raise_error(RuntimeError, /Cannot execute/)
    end
  end

  describe "#cancel!" do
    it "cancels a pending payout" do
      scheduled_payout = create(:scheduled_payout, status: "pending")
      scheduled_payout.cancel!
      expect(scheduled_payout.reload.status).to eq("cancelled")
    end

    it "cancels a flagged payout" do
      scheduled_payout = create(:scheduled_payout, status: "flagged")
      scheduled_payout.cancel!
      expect(scheduled_payout.reload.status).to eq("cancelled")
    end

    it "raises if already executed" do
      scheduled_payout = create(:scheduled_payout, status: "executed")
      expect { scheduled_payout.cancel! }.to raise_error(RuntimeError, /Cannot cancel/)
    end
  end

  describe "#user_has_active_chargebacks?" do
    let(:user) { create(:user) }
    let(:product) { create(:product, user: user) }
    let(:scheduled_payout) { create(:scheduled_payout, user: user) }

    it "returns false when user has no chargebacks" do
      expect(scheduled_payout.user_has_active_chargebacks?).to be false
    end

    it "returns true when user has unreversed chargebacks" do
      create(:free_purchase, link: product, chargeback_date: 2.days.ago)
      expect(scheduled_payout.user_has_active_chargebacks?).to be true
    end

    it "returns false when chargebacks are reversed" do
      create(:free_purchase, link: product, chargeback_date: 2.days.ago, chargeback_reversed: true)
      expect(scheduled_payout.user_has_active_chargebacks?).to be false
    end

    it "returns true when user has active disputes" do
      purchase = create(:free_purchase, link: product)
      create(:dispute, purchase: purchase, seller: user)
      expect(scheduled_payout.user_has_active_chargebacks?).to be true
    end

    it "returns false when disputes are won" do
      purchase = create(:free_purchase, link: product)
      dispute = create(:dispute, purchase: purchase, seller: user)
      dispute.mark_formalized!
      dispute.mark_won!
      expect(scheduled_payout.user_has_active_chargebacks?).to be false
    end
  end

  describe "#execute! with chargebacks" do
    let(:user) { create(:user) }
    let(:product) { create(:product, user: user) }

    it "flags for review and sends email when user has active chargebacks" do
      scheduled_payout = create(:scheduled_payout, user: user, action: "payout", scheduled_at: 1.day.ago)
      create(:free_purchase, link: product, chargeback_date: 2.days.ago)

      expect { scheduled_payout.execute! }
        .to have_enqueued_mail(CreatorMailer, :scheduled_payout_chargeback_hold)
        .with(scheduled_payout_id: scheduled_payout.id)

      expect(scheduled_payout.reload.status).to eq("flagged")
    end
  end
end
