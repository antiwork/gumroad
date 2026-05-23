# frozen_string_literal: true

require "test_helper"

class AdminUnreviewedUsersServiceTest < ActiveSupport::TestCase
  self.described_class = Admin::UnreviewedUsersService



  context_ Admin::UnreviewedUsersService do
  context_ "#count" do
  test "returns the total count of unreviewed users with unpaid balance" do
        2.times do
          user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
          create(:balance, user:, amount_cents: 15_000)
        end

        expect(described_class.new.count).to eq(2)
      end

  test "excludes users with balance <= $100" do
        user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
        create(:balance, user:, amount_cents: 5_000)

        expect(described_class.new.count).to eq(0)
      end
    end

  context_ "#users_with_unpaid_balance" do
  test "returns users ordered by total balance descending" do
        low_balance_user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
        create(:balance, user: low_balance_user, amount_cents: 15_000)

        high_balance_user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
        create(:balance, user: high_balance_user, amount_cents: 50_000)

        users = described_class.new.users_with_unpaid_balance

        expect(users.first.id).to eq(high_balance_user.id)
        expect(users.last.id).to eq(low_balance_user.id)
      end

  test "includes total_balance_cents attribute" do
        user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
        create(:balance, user:, amount_cents: 15_000)

        result = described_class.new.users_with_unpaid_balance.first

        expect(result.total_balance_cents).to eq(15_000)
      end

  test "excludes users with balance <= $100" do
        user_with_low_balance = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
        create(:balance, user: user_with_low_balance, amount_cents: 5_000)

        expect(described_class.new.users_with_unpaid_balance).to be_empty
      end

  test "excludes compliant users" do
        compliant_user = create(:user, user_risk_state: "compliant", created_at: 1.year.ago)
        create(:balance, user: compliant_user, amount_cents: 15_000)

        expect(described_class.new.users_with_unpaid_balance).to be_empty
      end

  test "excludes users created before cutoff date" do
        old_user = create(:user, user_risk_state: "not_reviewed", created_at: 3.years.ago)
        create(:balance, user: old_user, amount_cents: 15_000)

        expect(described_class.new.users_with_unpaid_balance).to be_empty
      end

  test "includes old users when cutoff_date is set in Redis" do
        old_user = create(:user, user_risk_state: "not_reviewed", created_at: Date.new(2023, 6, 1))
        create(:balance, user: old_user, amount_cents: 15_000)

        $redis.set(RedisKey.unreviewed_users_cutoff_date, "2023-01-01")
        users = described_class.new.users_with_unpaid_balance

        expect(users.map(&:id)).to include(old_user.id)
      end

  test "respects the limit parameter" do
        3.times do
          user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
          create(:balance, user:, amount_cents: 15_000)
        end

        users = described_class.new.users_with_unpaid_balance(limit: 2)

        expect(users.to_a.size).to eq(2)
      end
    end

  context_ ".cached_users_data" do
  test "returns nil when no cached data exists" do
        $redis.del(RedisKey.unreviewed_users_data)

        expect(described_class.cached_users_data).to be_nil
      end

  test "returns parsed data from Redis" do
        cache_payload = {
          users: [{ id: 1, email: "test@example.com" }],
          total_count: 1,
          cutoff_date: "2023-01-01",
          cached_at: "2024-01-01T00:00:00Z"
        }
        $redis.set(RedisKey.unreviewed_users_data, cache_payload.to_json)

        result = described_class.cached_users_data

        expect(result[:users].first[:email]).to eq("test@example.com")
        expect(result[:total_count]).to eq(1)
      end
    end

  context_ ".cache_users_data!" do
  test "caches user data in Redis" do
        user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
        create(:balance, user:, amount_cents: 15_000)

        result = described_class.cache_users_data!

        expect(result[:users].size).to eq(1)
        expect(result[:users].first[:external_id]).to eq(user.external_id)
        expect(result[:total_count]).to eq(1)
        expect(result[:cutoff_date]).to eq("2024-01-01")
        expect(result[:cached_at]).to be_present
      end

  test "stores data in Redis" do
        user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
        create(:balance, user:, amount_cents: 15_000)

        described_class.cache_users_data!

        cached = described_class.cached_users_data
        expect(cached[:users].first[:external_id]).to eq(user.external_id)
      end

  test "limits cached users to MAX_CACHED_USERS but total_count reflects true total" do
        stub_const("Admin::UnreviewedUsersService::MAX_CACHED_USERS", 2)

        3.times do |i|
          user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
          create(:balance, user:, amount_cents: 15_000 + (i * 5_000))
        end

        result = described_class.cache_users_data!

        expect(result[:users].size).to eq(2)
        expect(result[:total_count]).to eq(3)
      end
    end

  context_ ".cutoff_date" do
  test "defaults to 2024-01-01 when not set in Redis" do
        $redis.del(RedisKey.unreviewed_users_cutoff_date)

        expect(described_class.cutoff_date).to eq(Date.new(2024, 1, 1))
      end

  test "reads from Redis when set" do
        $redis.set(RedisKey.unreviewed_users_cutoff_date, "2023-06-15")

        expect(described_class.cutoff_date).to eq(Date.new(2023, 6, 15))
      end
    end
  end
end
