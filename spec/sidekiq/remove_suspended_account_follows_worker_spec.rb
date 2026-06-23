# frozen_string_literal: true

describe RemoveSuspendedAccountFollowsWorker do
  describe "#perform" do
    before do
      @creator = create(:user)
      @other_creator = create(:user)
      @follower_user = create(:user)
    end

    it "soft-deletes the suspended account's follows and clears confirmed_at" do
      follow_one = create(:active_follower, user: @creator, follower_user_id: @follower_user.id, email: @follower_user.email)
      follow_two = create(:active_follower, user: @other_creator, follower_user_id: @follower_user.id, email: @follower_user.email)

      @follower_user.suspend_for_fraud!(author_name: "test")

      described_class.new.perform(@follower_user.id)

      [follow_one, follow_two].each do |follow|
        follow.reload
        expect(follow.deleted_at).to be_present
        expect(follow.confirmed_at).to be_nil
      end
    end

    it "also removes email-only follows (follower_user_id nil) matching the account email" do
      email_only = create(:active_follower, user: @creator, follower_user_id: nil, email: @follower_user.email)

      @follower_user.suspend_for_fraud!(author_name: "test")

      described_class.new.perform(@follower_user.id)

      email_only.reload
      expect(email_only.deleted_at).to be_present
      expect(email_only.confirmed_at).to be_nil
    end

    it "does nothing when the user is not suspended" do
      follow = create(:active_follower, user: @creator, follower_user_id: @follower_user.id, email: @follower_user.email)

      described_class.new.perform(@follower_user.id)

      expect(follow.reload.deleted_at).to be_nil
    end

    it "leaves follows on the suspended creator's OWN follower list untouched" do
      # The suspended user is followed BY someone else — those edges are not theirs to lose.
      inbound_follow = create(:active_follower, user: @follower_user, follower_user_id: @creator.id, email: @creator.email)

      @follower_user.suspend_for_fraud!(author_name: "test")

      described_class.new.perform(@follower_user.id)

      expect(inbound_follow.reload.deleted_at).to be_nil
    end

    it "is idempotent — already-deleted follows are skipped" do
      follow = create(:active_follower, user: @creator, follower_user_id: @follower_user.id, email: @follower_user.email)
      follow.mark_deleted!
      deleted_at = follow.reload.deleted_at

      @follower_user.suspend_for_fraud!(author_name: "test")

      described_class.new.perform(@follower_user.id)

      expect(follow.reload.deleted_at).to eq(deleted_at)
    end
  end

  describe "suspension transition" do
    it "enqueues the worker when an account is suspended for fraud" do
      user = create(:user)

      expect do
        user.suspend_for_fraud!(author_name: "test")
      end.to change { RemoveSuspendedAccountFollowsWorker.jobs.size }.by(1)

      expect(RemoveSuspendedAccountFollowsWorker.jobs.last["args"]).to eq([user.id])
    end

    it "enqueues the worker when an account is suspended for a TOS violation" do
      user = create(:user)

      expect do
        user.suspend_for_tos_violation!(author_name: "test")
      end.to change { RemoveSuspendedAccountFollowsWorker.jobs.size }.by(1)
    end
  end
end
