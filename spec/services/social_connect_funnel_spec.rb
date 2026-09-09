# frozen_string_literal: true

require "spec_helper"

describe SocialConnectFunnel do
  let(:user) { create(:user) }

  describe ".record!" do
    it "writes a permitted event with provider and surface" do
      described_class.record!(user:, stage: "offered", provider: "twitter", surface: "getting_started")

      event = Event.last
      expect(event.event_name).to eq("social_connect_offered")
      expect(event.user_id).to eq(user.id)
      expect(event.parent_referrer).to eq("twitter")
      expect(event.view_url).to eq("getting_started")
      expect(Event::PERMITTED_NAMES).to include("social_connect_offered")
    end

    it "does not duplicate once:true rows for the same user, provider, and surface" do
      2.times { described_class.record!(user:, stage: "offered", provider: "youtube", surface: "account_review", once: true) }

      expect(Event.where(event_name: "social_connect_offered", user_id: user.id).count).to eq(1)
    end

    it "keeps an offered-without-attempted seller as a skipped row, not a zero duration" do
      described_class.record!(user:, stage: "offered", provider: "instagram", surface: "getting_started")

      metrics = SocialConnectFunnelReport.new(since: 1.hour.ago).to_h[:per_provider]["instagram"]
      expect(metrics[:offered]).to eq(1)
      expect(metrics[:attempted]).to eq(0)
      expect(metrics[:skipped_unattempted]).to eq(1)
      expect(metrics[:abandonment_rate]).to eq(1.0)
    end

    it "swallows write failures so connect paths cannot 500" do
      allow(Event).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect {
        described_class.record!(user:, stage: "connected", provider: "twitter", surface: "omniauth")
      }.not_to raise_error
    end
  end

  describe ".record_offers!" do
    it "records one offered event per unconnected provider and ignores already-connected ones" do
      described_class.record_offers!(
        user:,
        connections: [
          { name: "X", connected: false },
          { name: "YouTube", connected: true },
          { provider: "instagram", connected: false },
        ],
        surface: "getting_started",
      )

      names = Event.where(user_id: user.id, event_name: "social_connect_offered").pluck(:parent_referrer)
      expect(names).to match_array(%w[twitter instagram])
    end

    it "does not write when skip: true" do
      described_class.record_offers!(
        user:,
        connections: [{ provider: "twitter", connected: false }],
        surface: "account_review",
        skip: true,
      )

      expect(Event.where(event_name: "social_connect_offered")).to be_empty
    end
  end

  describe ".record_attempted_from_omniauth!" do
    it "records YouTube connect starts" do
      env = {
        "omniauth.strategy" => double(name: "youtube"),
        "warden" => double(user:),
      }

      described_class.record_attempted_from_omniauth!(env)

      expect(Event.last).to have_attributes(event_name: "social_connect_attempted", parent_referrer: "youtube", user_id: user.id)
    end

    it "ignores Twitter login that is not a link-account request" do
      env = {
        "omniauth.strategy" => double(name: "twitter"),
        "omniauth.params" => {},
        "QUERY_STRING" => "",
        "warden" => double(user:),
      }

      described_class.record_attempted_from_omniauth!(env)

      expect(Event.where(event_name: "social_connect_attempted")).to be_empty
    end

    it "records Twitter when the request is a link-account state" do
      env = {
        "omniauth.strategy" => double(name: "twitter"),
        "omniauth.params" => { "state" => "link_twitter_account" },
        "QUERY_STRING" => "",
        "warden" => double(user:),
      }

      described_class.record_attempted_from_omniauth!(env)

      expect(Event.last.parent_referrer).to eq("twitter")
    end
  end

  describe ".record_reviewed!" do
    it "records provider none when the seller has no live connection" do
      described_class.record_reviewed!(user:, verifications: [])

      expect(Event.last).to have_attributes(event_name: "social_connect_reviewed", parent_referrer: "none")
    end
  end
end
