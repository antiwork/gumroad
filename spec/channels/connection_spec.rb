# frozen_string_literal: true

require "spec_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
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

  describe "#connect" do
    it "connects with valid user" do
      connect_with_user(user)
      expect(connection.current_user).to eq(user)
    end

    context "when user is a gumroad admin" do
      it "connects with gumroad admin when impersonation is not set" do
        connect_with_user(gumroad_admin_user)
        expect(connection.current_user).to eq(gumroad_admin_user)
      end

      it "connects with impersonated user when set" do
        $redis.set(RedisKey.impersonated_user(gumroad_admin_user.id), impersonated_user.id)
        connect_with_user(gumroad_admin_user)
        expect(connection.current_user).to eq(impersonated_user)
      end

      it "connects with gumroad admin when impersonated user is not found" do
        $redis.set(RedisKey.impersonated_user(gumroad_admin_user.id), -1)
        connect_with_user(gumroad_admin_user)
        expect(connection.current_user).to eq(gumroad_admin_user)
      end

      it "connects with gumroad admin when impersonated user is not active" do
        impersonated_user.update!(user_risk_state: "suspended_for_fraud")
        $redis.set(RedisKey.impersonated_user(gumroad_admin_user.id), impersonated_user.id)
        connect_with_user(gumroad_admin_user)
        expect(connection.current_user).to eq(gumroad_admin_user)
      end
    end

    it "rejects connection when user is not found" do
      expect { connect_with_user(nil) }.to have_rejected_connection
    end
  end
end
