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

    it "does NOT delete a follow linked to a different account that shares a stale email" do
      # Another account's row carries the same email (e.g. after an email change) but is
      # explicitly linked to its own follower_user_id — it must not be collateral.
      other_account = create(:user)
      foreign_follow = create(:active_follower, user: @creator, follower_user_id: other_account.id, email: @follower_user.email)

      @follower_user.suspend_for_fraud!(author_name: "test")

      described_class.new.perform(@follower_user.id)

      expect(foreign_follow.reload.deleted_at).to be_nil
    end

    it "matches email-only follows under the confirmed email but NOT an unverified pending email" do
      @follower_user.update!(unconfirmed_email: "pending-change@example.com")
      under_confirmed = create(:active_follower, user: @creator, follower_user_id: nil, email: @follower_user.email)
      under_pending = create(:active_follower, user: @other_creator, follower_user_id: nil, email: "pending-change@example.com")

      @follower_user.suspend_for_fraud!(author_name: "test")

      described_class.new.perform(@follower_user.id)

      # Confirmed (verified) email follows are removed; unverified pending-email follows are NOT
      # touched — otherwise a suspended account could unsubscribe a victim by setting their address.
      expect(under_confirmed.reload.deleted_at).to be_present
      expect(under_pending.reload.deleted_at).to be_nil
    end

    it "does NOT match null-email follows when the suspended account has no email" do
      # Accounts can have a nil email (presence is conditional). The email-only branch must skip
      # entirely in that case — otherwise `email = nil` would match (and delete) every null-email
      # follower row, none of which is known to belong to the suspended account.
      null_email_follow = create(:active_follower, user: @creator, follower_user_id: nil, email: "stray@example.com")
      null_email_follow.update_column(:email, nil)

      @follower_user.suspend_for_fraud!(author_name: "test")
      @follower_user.update_column(:email, nil)

      described_class.new.perform(@follower_user.id)

      expect(null_email_follow.reload.deleted_at).to be_nil
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
