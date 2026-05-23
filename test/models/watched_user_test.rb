# frozen_string_literal: true

require "test_helper"

class WatchedUserTest < ActiveSupport::TestCase
  self.described_class = WatchedUser



  context_ WatchedUser do
  context_ "validations" do
  test "is valid with valid attributes" do
        expect(build(:watched_user)).to be_valid
      end

  test "requires a positive revenue_threshold_cents" do
        expect(build(:watched_user, revenue_threshold_cents: nil)).not_to be_valid
        expect(build(:watched_user, revenue_threshold_cents: 0)).not_to be_valid
        expect(build(:watched_user, revenue_threshold_cents: -100)).not_to be_valid
      end

  test "prevents creating a second alive watch for the same user" do
        user = create(:user)
        create(:watched_user, user: user)
        duplicate = build(:watched_user, user: user)
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:base]).to include("User is already being watched")
      end

  test "allows a new watch once the previous one is soft-deleted" do
        user = create(:user)
        previous = create(:watched_user, user: user)
        previous.mark_deleted!
        expect(build(:watched_user, user: user)).to be_valid
      end
    end

  context_ "scopes" do
      let!(:alive_watch) { create(:watched_user) }
      let!(:deleted_watch) do
        watch = create(:watched_user)
        watch.mark_deleted!
        watch
      end

  test ".alive returns only non-deleted watches" do
        expect(WatchedUser.alive).to contain_exactly(alive_watch)
      end

  test ".deleted returns only soft-deleted watches" do
        expect(WatchedUser.deleted).to contain_exactly(deleted_watch)
      end

  test ".for_user returns watches for the given user" do
        other_watch = create(:watched_user)
        expect(WatchedUser.for_user(alive_watch.user)).to contain_exactly(alive_watch)
        expect(WatchedUser.for_user(other_watch.user)).to contain_exactly(other_watch)
      end
    end

  context_ "#sync!" do
  test "snapshots total revenue, current unpaid balance, and stamps last_synced_at" do
        user = create(:user)
        watch = create(:watched_user, user: user, revenue_threshold_cents: 20_000)

        allow(user).to receive(:sales_cents_total).and_return(15_000)
        allow(user).to receive(:unpaid_balance_cents).and_return(7_250)
        allow(watch).to receive(:user).and_return(user)

        freeze_time do
          watch.sync!

          expect(watch.revenue_cents).to eq(15_000)
          expect(watch.unpaid_balance_cents).to eq(7_250)
          expect(watch.last_synced_at).to eq(Time.current)
        end
      end
    end

  context_ "User associations" do
  test "exposes watched_users and active_watched_user" do
        user = create(:user)
        watch = create(:watched_user, user: user)

        expect(user.watched_users).to contain_exactly(watch)
        expect(user.active_watched_user).to eq(watch)

        watch.mark_deleted!

        expect(user.reload.active_watched_user).to be_nil
        expect(user.watched_users).to contain_exactly(watch)
      end
    end
  end
end
