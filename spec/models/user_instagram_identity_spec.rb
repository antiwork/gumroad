# frozen_string_literal: true

require "spec_helper"

describe UserInstagramIdentity do
  let(:identity) { create(:user_instagram_identity) }

  it "stores the publishing token encrypted and reads it back" do
    identity.update!(access_token: "ig-token", access_token_expires_at: 30.days.from_now)

    expect(identity.reload.access_token).to eq("ig-token")
    expect(identity.encrypted_access_token).to be_present
    expect(identity.encrypted_access_token).not_to include("ig-token")
  end

  it "can publish only with a token that has not expired" do
    expect(identity.can_publish?).to eq(false)

    identity.update!(access_token: "ig-token", access_token_expires_at: 30.days.from_now)
    expect(identity.can_publish?).to eq(true)

    identity.update!(access_token_expires_at: 1.minute.ago)
    expect(identity.can_publish?).to eq(false)
  end

  it "clears the stored token when it is set to blank" do
    identity.update!(access_token: "ig-token", access_token_expires_at: 30.days.from_now)
    identity.update!(access_token: nil)

    expect(identity.reload.encrypted_access_token).to be_nil
  end

  it "is due for a refresh only in the last week of a live token" do
    identity.update!(access_token: "ig-token", access_token_expires_at: 30.days.from_now)
    expect(identity.token_due_for_refresh?).to eq(false)

    identity.update!(access_token_expires_at: 3.days.from_now)
    expect(identity.token_due_for_refresh?).to eq(true)

    identity.update!(access_token_expires_at: 1.day.ago)
    expect(identity.token_due_for_refresh?).to eq(false)
  end

  it "reads an undecryptable token as no token" do
    identity.update_columns(encrypted_access_token: "garbage")

    expect(identity.access_token).to be_nil
    expect(identity.can_publish?).to eq(false)
  end
end
