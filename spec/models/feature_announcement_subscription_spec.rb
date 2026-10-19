# frozen_string_literal: true

require "spec_helper"

describe FeatureAnnouncementSubscription do
  let(:user) { create(:user, email: "creator@example.com") }

  describe ".state_for" do
    it "treats a user with no row as not subscribed" do
      expect(described_class.state_for(user)).to eq(subscribed: false, version: 0)
      expect(described_class.subscribed?(user)).to be(false)
    end

    it "leaves the shared announcement preference alone for new users" do
      expect(user.announcement_notification_enabled).to be(true)
      expect(described_class.subscribed?(user)).to be(false)
    end
  end

  describe ".unsubscribe!" do
    it "writes an opt-out row when the user never had one" do
      described_class.unsubscribe!(user, source: "unsubscribe_link")

      row = described_class.find_by!(user_id: user.id)
      expect(row.attributes.slice("subscribed", "version", "source")).to eq("subscribed" => false, "version" => 1, "source" => "unsubscribe_link")
    end

    it "turns off a subscription and bumps its version" do
      described_class.create!(user_id: user.id, subscribed: true, source: "settings")

      described_class.unsubscribe!(user, source: "unsubscribe_link")

      expect(described_class.find_by!(user_id: user.id).attributes.slice("subscribed", "version", "source"))
        .to eq("subscribed" => false, "version" => 2, "source" => "unsubscribe_link")
    end

    it "is idempotent" do
      described_class.create!(user_id: user.id, subscribed: true, source: "settings")

      3.times { described_class.unsubscribe!(user, source: "unsubscribe_link") }

      expect(described_class.where(user_id: user.id).pluck(:subscribed, :version)).to eq([[false, 2]])
    end

    it "does not touch the other notification preferences" do
      expect do
        described_class.unsubscribe!(user, source: "unsubscribe_link")
      end.not_to change { user.reload.attributes.slice("flags", "notification_endpoint") }
      expect(user.announcement_notification_enabled).to be(true)
    end
  end

  describe ".update_from_settings!" do
    it "subscribes a user who had no row" do
      expect(described_class.update_from_settings!(user, subscribed: true, rendered_version: 0)).to eq(:updated)
      expect(described_class.state_for(user)).to eq(subscribed: true, version: 1)
    end

    it "does not let a form rendered before an unsubscribe switch the emails back on" do
      described_class.update_from_settings!(user, subscribed: true, rendered_version: 0)
      rendered_version = described_class.state_for(user)[:version]
      described_class.unsubscribe!(user, source: "unsubscribe_link")

      expect(described_class.update_from_settings!(user, subscribed: true, rendered_version:)).to eq(:stale)
      expect(described_class.state_for(user)).to eq(subscribed: false, version: 2)
    end

    it "does not let a form rendered before a first opt-out subscribe the user" do
      described_class.unsubscribe!(user, source: "unsubscribe_link")

      expect(described_class.update_from_settings!(user, subscribed: true, rendered_version: 0)).to eq(:stale)
      expect(described_class.state_for(user)).to eq(subscribed: false, version: 1)
    end

    it "accepts a change made from the current version" do
      described_class.unsubscribe!(user, source: "unsubscribe_link")

      expect(described_class.update_from_settings!(user, subscribed: true, rendered_version: 1)).to eq(:updated)
      expect(described_class.state_for(user)).to eq(subscribed: true, version: 2)
    end

    it "ignores a resubmitted value that already matches, whatever the version" do
      described_class.unsubscribe!(user, source: "unsubscribe_link")

      expect(described_class.update_from_settings!(user, subscribed: false, rendered_version: 0)).to eq(:unchanged)
      expect(described_class.state_for(user)).to eq(subscribed: false, version: 1)
    end
  end

  describe "unsubscribe tokens" do
    it "round-trips the user and the recipient address" do
      token = described_class.unsubscribe_token(user, "Creator@Example.com ")

      expect(described_class.decode_unsubscribe_token(token)).to eq([user.id, described_class.address_digest("creator@example.com")])
    end

    it "does not expose the user id or address in the link" do
      token = described_class.unsubscribe_token(user, user.email)
      decoded = Base64.urlsafe_decode64(token)

      expect(decoded).not_to include(user.id.to_s)
      expect(decoded).not_to include("creator@example.com")
      expect(decoded).not_to include(described_class.address_digest(user.email))
    end

    it "rejects tokens minted for other unsubscribe links" do
      expect(described_class.decode_unsubscribe_token(user.secure_external_id(scope: "email_unsubscribe"))).to be_nil
      expect(described_class.decode_unsubscribe_token(user.secure_external_id(scope: Users::ReviewRemindersController::TOKEN_SCOPE))).to be_nil
      expect(described_class.decode_unsubscribe_token(user.secure_external_id(scope: described_class::UNSUBSCRIBE_TOKEN_SCOPE))).to be_nil
    end

    it "is not accepted by the other unsubscribe links" do
      token = described_class.unsubscribe_token(user, user.email)

      expect(User.find_by_secure_external_id(token, scope: "email_unsubscribe")).to be_nil
      expect(User.find_by_secure_external_id(token, scope: Users::ReviewRemindersController::TOKEN_SCOPE)).to be_nil
    end

    it "rejects a tampered token" do
      token = described_class.unsubscribe_token(user, user.email)
      outer = JSON.parse(Base64.urlsafe_decode64(token))
      outer["d"] = outer["d"].sub(/\A./) { _1 == "A" ? "B" : "A" }

      expect(described_class.decode_unsubscribe_token(Base64.urlsafe_encode64(outer.to_json, padding: false))).to be_nil
      expect(described_class.decode_unsubscribe_token("not-a-token")).to be_nil
    end
  end
end
