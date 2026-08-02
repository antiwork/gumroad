# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillFirstPartyStoreAgentOauthApplications do
  def create_matching_agent_app(**attrs)
    create(
      :oauth_application,
      {
        name: Ai::StoreAgentApiClient::AGENT_APP_NAME,
        owner_type: "User",
        redirect_uri: Ai::StoreAgentApiClient::AGENT_APP_REDIRECT_URI,
        scopes: Ai::StoreAgentApiClient::AGENT_APP_SCOPES,
      }.merge(attrs),
    )
  end

  describe ".process" do
    it "flags a fingerprint-matching app" do
      application = create_matching_agent_app

      stats = described_class.process(dry_run: false)

      expect(application.reload.is_first_party_agent_app?).to be(true)
      expect(stats[:matched_count]).to eq(1)
      expect(stats[:flagged_count]).to eq(1)
    end

    it "does not flag a same-name app with a foreign redirect URI" do
      application = create_matching_agent_app(redirect_uri: "https://example.com/oauth/callback")

      stats = described_class.process(dry_run: false)

      expect(application.reload.is_first_party_agent_app?).to be(false)
      expect(stats[:matched_count]).to eq(0)
      expect(stats[:flagged_count]).to eq(0)
    end

    it "does not flag a same-name app with different scopes" do
      application = create_matching_agent_app(scopes: "account")

      stats = described_class.process(dry_run: false)

      expect(application.reload.is_first_party_agent_app?).to be(false)
      expect(stats[:matched_count]).to eq(0)
      expect(stats[:flagged_count]).to eq(0)
    end

    it "flags a soft-deleted fingerprint-matching app" do
      application = create_matching_agent_app
      application.update_column(:deleted_at, Time.current)

      stats = described_class.process(dry_run: false)

      expect(application.reload.is_first_party_agent_app?).to be(true)
      expect(stats[:matched_count]).to eq(1)
      expect(stats[:flagged_count]).to eq(1)
    end

    it "is idempotent on a second run" do
      application = create_matching_agent_app

      described_class.process(dry_run: false)
      stats = described_class.process(dry_run: false)

      expect(application.reload.is_first_party_agent_app?).to be(true)
      expect(stats[:matched_count]).to eq(1)
      expect(stats[:flagged_count]).to eq(0)
    end

    it "writes nothing during a dry run" do
      application = create_matching_agent_app

      stats = described_class.process

      expect(application.reload.is_first_party_agent_app?).to be(false)
      expect(stats[:matched_count]).to eq(1)
      expect(stats[:would_flag_count]).to eq(1)
      expect(stats[:dry_run]).to eq(true)
    end
  end
end
