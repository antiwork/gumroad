# frozen_string_literal: true

require "spec_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  let!(:user) { create(:user) }

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

    it "rejects connection when user is not found" do
      expect { connect_with_user(nil) }.to have_rejected_connection
    end
  end
end
