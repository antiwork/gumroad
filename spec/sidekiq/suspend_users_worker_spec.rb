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

    it "suspends the users appropriately" do
      described_class.new.perform(admin_user.id, user_ids_to_suspend, reason, additional_notes)

      expect(not_reviewed_user.reload.suspended?).to be(true)
      expect(compliant_user.reload.suspended?).to be(true)
      expect(already_suspended_user.reload.suspended?).to be(true)
      expect(user_not_to_suspend.reload.suspended?).to be(false)

      comments = not_reviewed_user.comments
      expect(comments.count).to eq(2)
      expect(comments.first.content).to eq("Flagged for a policy violation by #{admin_user.name_or_username} on #{Time.current.to_fs(:formatted_date_full_month)}")
      expect(comments.first.author_id).to eq(admin_user.id)
      expect(comments.last.content).to eq("Suspended for a policy violation by #{admin_user.name_or_username} on #{Time.current.to_fs(:formatted_date_full_month)} as part of mass suspension. Reason: #{reason}.\nAdditional notes: #{additional_notes}")
      expect(comments.last.author_id).to eq(admin_user.id)
    end
  end
end
