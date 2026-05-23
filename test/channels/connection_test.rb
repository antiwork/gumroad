# frozen_string_literal: true

require "test_helper"

class ApplicationCableConnectionTest < ActionCable::Channel::TestCase
  self.described_class = ApplicationCable::Connection



  context_ ApplicationCable::Connection, type: :channel do
    let!(:user) { create(:user) }
    let!(:gumroad_admin_user) { create(:user, is_team_member: true) }
    let!(:impersonated_user) { create(:user) }

    def connect_with_user(user)
      if user
        session = { "warden.user.user.key" => [[user.id], nil] }
      else
        session = {}
      end

      connect session: session
    end

  context_ "#connect" do
  test "connects with valid user" do
        connect_with_user(user)
        expect(connection.current_user).to eq(user)
      end

  context_ "when user is a gumroad admin" do
  test "connects with gumroad admin when impersonation is not set" do
          connect_with_user(gumroad_admin_user)
          expect(connection.current_user).to eq(gumroad_admin_user)
        end

  test "connects with impersonated user when set" do
          $redis.set(RedisKey.impersonated_user(gumroad_admin_user.id), impersonated_user.id)
          connect_with_user(gumroad_admin_user)
          expect(connection.current_user).to eq(impersonated_user)
        end

  test "connects with gumroad admin when impersonated user is not found" do
          $redis.set(RedisKey.impersonated_user(gumroad_admin_user.id), -1)
          connect_with_user(gumroad_admin_user)
          expect(connection.current_user).to eq(gumroad_admin_user)
        end

  test "connects with gumroad admin when impersonated user is not active" do
          impersonated_user.update!(user_risk_state: "suspended_for_fraud")
          $redis.set(RedisKey.impersonated_user(gumroad_admin_user.id), impersonated_user.id)
          connect_with_user(gumroad_admin_user)
          expect(connection.current_user).to eq(gumroad_admin_user)
        end
      end

  test "rejects connection when user is not found" do
        expect { connect_with_user(nil) }.to have_rejected_connection
      end
    end
  end
end
