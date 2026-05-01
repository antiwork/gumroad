# frozen_string_literal: true

require "spec_helper"

describe AdminApiToken do
  describe ".mint!" do
    it "stores the token hash and returns the plaintext token once" do
      actor = create(:admin_user)

      plaintext_token = described_class.mint!(actor_user_id: actor.id)
      admin_api_token = described_class.find_by!(actor_user: actor, token_hash: described_class.hash_token(plaintext_token))

      expect(plaintext_token).to be_present
      expect(admin_api_token.token_hash).to eq(described_class.hash_token(plaintext_token))
      expect(admin_api_token.token_hash).not_to eq(plaintext_token)
      expect(admin_api_token).to have_attributes(
        actor_user: actor,
        external_id: a_string_matching(/\A[-_0-9a-zA-Z]{21}\z/)
      )
    end
  end

  describe ".mint_with_plaintext!" do
    it "returns the plaintext token and token row" do
      actor = create(:admin_user)

      plaintext_token, admin_api_token = described_class.mint_with_plaintext!(actor_user_id: actor.id, expires_at: 30.days.from_now)

      expect(plaintext_token).to be_present
      expect(admin_api_token).to have_attributes(
        actor_user: actor,
        token_hash: described_class.hash_token(plaintext_token),
        expires_at: be_present
      )
    end
  end

  describe ".seed_legacy_admin_token!" do
    it "creates the legacy admin token from the configured shared token" do
      actor = create(:admin_user)
      stub_const("GUMROAD_ADMIN_ID", actor.id)
      allow(GlobalConfig).to receive(:get).with("INTERNAL_ADMIN_API_TOKEN").and_return("legacy-token")

      admin_api_token = described_class.seed_legacy_admin_token!

      expect(admin_api_token).to have_attributes(
        actor_user: actor,
        token_hash: described_class.hash_token("legacy-token")
      )
      expect { described_class.seed_legacy_admin_token! }.not_to change(described_class, :count)
    end

    it "does not create a token when the configured shared token is blank" do
      allow(GlobalConfig).to receive(:get).with("INTERNAL_ADMIN_API_TOKEN").and_return("")

      expect(described_class.seed_legacy_admin_token!).to be_nil
      expect(described_class.count).to eq(0)
    end
  end

  describe ".authenticate" do
    it "returns an active token for the matching plaintext token" do
      actor = create(:admin_user)
      plaintext_token = described_class.mint!(actor_user_id: actor.id)
      admin_api_token = described_class.find_by!(actor_user: actor, token_hash: described_class.hash_token(plaintext_token))

      expect(described_class.authenticate(plaintext_token)).to eq(admin_api_token)
    end

    it "does not authenticate revoked or expired tokens" do
      actor = create(:admin_user)
      revoked_plaintext_token = described_class.mint!(actor_user_id: actor.id)
      revoked_token = described_class.find_by!(actor_user: actor, token_hash: described_class.hash_token(revoked_plaintext_token))
      expired_plaintext_token = described_class.mint!(actor_user_id: actor.id, expires_at: 1.minute.ago)
      revoked_token.update!(revoked_at: Time.current)

      expect(described_class.authenticate(revoked_plaintext_token)).to be_nil
      expect(described_class.authenticate(expired_plaintext_token)).to be_nil
      expect(described_class.authenticate("missing")).to be_nil
    end
  end

  describe "#legacy_admin_token?" do
    it "only treats the seeded legacy row as the legacy admin token" do
      legacy_actor = create(:admin_user)
      service_actor = create(:admin_user)
      stub_const("GUMROAD_ADMIN_ID", legacy_actor.id)
      legacy_admin_token = create(:admin_api_token, actor_user: legacy_actor)
      later_admin_actor_token = create(:admin_api_token, actor_user: legacy_actor)
      service_token = create(:admin_api_token, actor_user: service_actor)

      expect(legacy_admin_token).to be_legacy_admin_token
      expect(later_admin_actor_token).not_to be_legacy_admin_token
      expect(service_token).not_to be_legacy_admin_token
    end
  end

  describe "#record_used!" do
    it "extends expiring tokens by 30 days capped at 90 days from creation" do
      actor = create(:admin_user)
      plaintext_token, admin_api_token = described_class.mint_with_plaintext!(actor_user_id: actor.id, expires_at: 1.day.from_now)
      created_at = 80.days.ago
      admin_api_token.update_columns(created_at:, updated_at: created_at)

      freeze_time do
        admin_api_token.record_used!

        admin_api_token.reload
        expect(admin_api_token.last_used_at).to be_within(1.second).of(Time.current)
        expect(admin_api_token.expires_at).to be_within(1.second).of(created_at + 90.days)
        expect(described_class.authenticate(plaintext_token)).to eq(admin_api_token)
      end
    end

    it "does not add expiry to service tokens" do
      admin_api_token = create(:admin_api_token, expires_at: nil)

      admin_api_token.record_used!

      expect(admin_api_token.reload.expires_at).to be_nil
      expect(admin_api_token.last_used_at).to be_present
    end
  end
end
