# frozen_string_literal: true

describe SuspendUsersWorker do
  describe "#perform" do
    let(:admin_user) { create(:admin_user) }
    let(:not_reviewed_user) { create(:user) }
    let(:compliant_user) { create(:compliant_user) }
    let(:already_suspended_user) { create(:user, user_risk_state: :suspended_for_fraud) }
    let!(:user_not_to_suspend) { create(:user) }
    let(:user_ids_to_suspend) { [not_reviewed_user.id, compliant_user.id, already_suspended_user.id] }
    let(:reason) { "Violating our terms of service" }
    let(:additional_notes) { "Some additional notes" }

    it "suspends the users appropriately with IDs" do
      described_class.new.perform(admin_user.id, user_ids_to_suspend, reason, additional_notes)

      expect(not_reviewed_user.reload.suspended?).to be(true)
      expect(compliant_user.reload.suspended?).to be(true)
      expect(already_suspended_user.reload.suspended?).to be(true)
      expect(user_not_to_suspend.reload.suspended?).to be(false)

      comments = not_reviewed_user.comments
      expect(comments.count).to eq(1)
      expect(comments.first.content).to eq("Suspended for a policy violation by #{admin_user.name_or_username} on #{Time.current.to_fs(:formatted_date_full_month)} as part of mass suspension. Reason: #{reason}.\nAdditional notes: #{additional_notes}")
      expect(comments.first.author_id).to eq(admin_user.id)
    end

    it "suspends the users appropriately with external IDs" do
      external_ids_to_suspend = [not_reviewed_user.external_id, compliant_user.external_id, already_suspended_user.external_id]
      described_class.new.perform(admin_user.id, external_ids_to_suspend, reason, additional_notes)

      expect(not_reviewed_user.reload.suspended?).to be(true)
      expect(compliant_user.reload.suspended?).to be(true)
      expect(already_suspended_user.reload.suspended?).to be(true)
      expect(user_not_to_suspend.reload.suspended?).to be(false)
    end

    it "suspends the users appropriately with mixed internal and external IDs" do
      mixed_ids = [not_reviewed_user.id, compliant_user.external_id, already_suspended_user.id]
      described_class.new.perform(admin_user.id, mixed_ids, reason, additional_notes)

      expect(not_reviewed_user.reload.suspended?).to be(true)
      expect(compliant_user.reload.suspended?).to be(true)
      expect(already_suspended_user.reload.suspended?).to be(true)
      expect(user_not_to_suspend.reload.suspended?).to be(false)
    end

    context "with scheduled payout params" do
      let(:scheduled_payout) { { "action" => "payout", "delay_days" => "14" } }

      before do
        allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(5_000)
      end

      it "creates a scheduled payout for newly-suspended users" do
        described_class.new.perform(admin_user.id, user_ids_to_suspend, reason, additional_notes, scheduled_payout)

        [not_reviewed_user, compliant_user].each do |user|
          user.reload
          expect(user.scheduled_payouts.count).to eq(1)
          sp = user.scheduled_payouts.last
          expect(sp.action).to eq("payout")
          expect(sp.delay_days).to eq(14)
          expect(sp.payout_amount_cents).to eq(5_000)
          expect(sp.created_by).to eq(admin_user)

          payout_comment = user.comments.with_type_payout_note.last
          expect(payout_comment).to be_present
          expect(payout_comment.content).to include("Scheduled payout")
        end
      end

      it "does not create a scheduled payout for users who were already suspended" do
        described_class.new.perform(admin_user.id, user_ids_to_suspend, reason, additional_notes, scheduled_payout)

        expect(already_suspended_user.reload.scheduled_payouts.count).to eq(0)
      end

      it "defaults delay_days to 21 when not provided" do
        described_class.new.perform(admin_user.id, [not_reviewed_user.id], reason, additional_notes, { "action" => "payout", "delay_days" => nil })

        expect(not_reviewed_user.reload.scheduled_payouts.last.delay_days).to eq(21)
      end

      it "supports hold action" do
        described_class.new.perform(admin_user.id, [not_reviewed_user.id], reason, additional_notes, { "action" => "hold", "delay_days" => nil })

        sp = not_reviewed_user.reload.scheduled_payouts.last
        expect(sp.action).to eq("hold")
        expect(sp.delay_days).to eq(21)
      end

      it "does nothing when scheduled_payout is nil" do
        described_class.new.perform(admin_user.id, [not_reviewed_user.id], reason, additional_notes, nil)

        expect(not_reviewed_user.reload.scheduled_payouts.count).to eq(0)
      end

      it "does nothing when scheduled_payout action is blank" do
        described_class.new.perform(admin_user.id, [not_reviewed_user.id], reason, additional_notes, { "action" => "", "delay_days" => "14" })

        expect(not_reviewed_user.reload.scheduled_payouts.count).to eq(0)
      end

      it "does not create a scheduled payout when the user has no unpaid balance" do
        allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(0)

        described_class.new.perform(admin_user.id, [not_reviewed_user.id], reason, additional_notes, scheduled_payout)

        not_reviewed_user.reload
        expect(not_reviewed_user.suspended?).to be(true)
        expect(not_reviewed_user.scheduled_payouts.count).to eq(0)
        expect(not_reviewed_user.comments.with_type_payout_note.count).to eq(0)
      end
    end
  end
end
