# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Following do
  before do
    @user = create(:user, timezone: "UTC")
    @service = described_class.new(@user)
  end

  describe "#by_date" do
    it "returns expected data" do
      add_event("added", Time.utc(2021, 1, 1))
      add_event("added", Time.utc(2021, 1, 1))
      add_event("removed", Time.utc(2021, 1, 1))
      add_event("added", Time.utc(2021, 1, 2))
      add_event("added", Time.utc(2021, 1, 2))
      add_event("removed", Time.utc(2021, 1, 2))
      add_event("added", Time.utc(2021, 1, 4))
      ConfirmedFollowerEvent.__elasticsearch__.refresh_index!

      expect(@service).to receive(:counts).and_call_original
      expect(@service).to receive(:first_follower_date).and_call_original

      result = nil
      travel_to Time.utc(2021, 1, 4) do
        result = @service.by_date(start_date: Date.new(2021, 1, 2), end_date: Date.new(2021, 1, 4))
      end

      expect(result).to eq(
        dates: ["Saturday, January 2nd", "Sunday, January 3rd", "Monday, January 4th"],
        by_date: {
          new_followers: [2, 0, 1],
          followers_removed: [1, 0, 0],
          totals: [2, 2, 3]
        },
        new_followers: 2,
        start_date: "Jan  2, 2021",
        end_date: "Today",
        first_follower_date: "Jan  1, 2021"
      )
    end

    it "returns expected data when user has no followers" do
      expect(@service).not_to receive(:counts)
      expect(@service).to receive(:zero_counts).and_call_original
      result = @service.by_date(start_date: Date.new(2021, 1, 1), end_date: Date.new(2021, 1, 2))
      expect(result).to eq(
        dates: ["Friday, January 1st", "Saturday, January 2nd"],
        by_date: {
          new_followers: [0, 0],
          followers_removed: [0, 0],
          totals: [0, 0]
        },
        new_followers: 0,
        start_date: "Jan  1, 2021",
        end_date: "Jan  2, 2021",
        first_follower_date: nil
      )
    end
  end

  describe "#net_total" do
    it "returns net total of followers" do
      add_event("added", Time.utc(2021, 1, 1))
      add_event("added", Time.utc(2021, 1, 1))
      add_event("removed", Time.utc(2021, 1, 1))
      add_event("added", Time.utc(2021, 1, 2))
      add_event("added", Time.utc(2021, 1, 2))
      add_event("removed", Time.utc(2021, 1, 2))
      ConfirmedFollowerEvent.__elasticsearch__.refresh_index!

      expect(@service.net_total).to eq(2)
    end

    context "up to a specific date" do
      it "returns net total of followers before that date" do
        add_event("added", Time.utc(2021, 1, 1))
        add_event("added", Time.utc(2021, 1, 2))
        add_event("removed", Time.utc(2021, 1, 3))
        ConfirmedFollowerEvent.__elasticsearch__.refresh_index!

        expect(@service.net_total(before_date: Date.new(2021, 1, 4))).to eq(1)
        expect(@service.net_total(before_date: Date.new(2021, 1, 3))).to eq(2)
        expect(@service.net_total(before_date: Date.new(2021, 1, 2))).to eq(1)
        expect(@service.net_total(before_date: Date.new(2021, 1, 1))).to eq(0)
      end

      it "supports time zones" do
        add_event("added", Time.utc(2021, 1, 2, 1)) # Jan 2nd @ 1AM in UTC == Jan 1st @ 8PM in EST
        ConfirmedFollowerEvent.__elasticsearch__.refresh_index!

        before_date = Date.new(2021, 1, 2)
        expect(@service.net_total(before_date:)).to eq(0)

        @user.update!(timezone: "Eastern Time (US & Canada)")
        expect(@service.net_total(before_date:)).to eq(1)
        expect(@service.net_total).to eq(1)
      end
    end
  end

  describe "#first_follower_date" do
    it "returns nil if there are no followers" do
      expect(@service.first_follower_date).to eq(nil)
    end

    it "returns the date of the first follower" do
      add_event("added", Time.utc(2021, 1, 1))
      add_event("added", Time.utc(2021, 3, 5))
      ConfirmedFollowerEvent.__elasticsearch__.refresh_index!

      expect(@service.first_follower_date).to eq(Date.new(2021, 1, 1))
    end

    it "supports time zones" do
      add_event("added", Time.utc(2021, 1, 1))
      ConfirmedFollowerEvent.__elasticsearch__.refresh_index!

      @user.update!(timezone: "Eastern Time (US & Canada)")
      expect(@service.first_follower_date).to eq(Date.new(2020, 12, 31))
    end
  end

  describe "#counts" do
    it "returns hash of followers added, removed and running net total by day" do
      # This also checks that:
      # - Days with no activity are handled: (2021, 1, 3) has no data so isn't returned by the internal ES query.
      # - Days with partial activity are handled: (2021, 1, 4) has no unfollows.
      add_event("added", Time.utc(2021, 1, 1))
      add_event("added", Time.utc(2021, 1, 1))
      add_event("removed", Time.utc(2021, 1, 1))
      add_event("added", Time.utc(2021, 1, 2))
      add_event("added", Time.utc(2021, 1, 2))
      add_event("removed", Time.utc(2021, 1, 2))
      add_event("added", Time.utc(2021, 1, 4))
      ConfirmedFollowerEvent.__elasticsearch__.refresh_index!

      expect(@service).to receive(:net_total).with(before_date: Date.new(2021, 1, 1)).and_call_original

      result = @service.send(:counts, (Date.new(2021, 1, 1) .. Date.new(2021, 1, 4)).to_a)
      expect(result).to eq({
                             new_followers: [2, 2, 0, 1],
                             followers_removed: [1, 1, 0, 0],
                             totals: [1, 2, 2, 3]
                           })

      expect(@service).to receive(:net_total).with(before_date: Date.new(2021, 1, 3)).and_call_original

      result = @service.send(:counts, (Date.new(2021, 1, 3) .. Date.new(2021, 1, 3)).to_a)
      expect(result).to eq({
                             new_followers: [0],
                             followers_removed: [0],
                             totals: [2]
                           })
    end
  end

  def add_event(name, timestamp)
    EsClient.index(
      index: ConfirmedFollowerEvent.index_name,
      body: {
        followed_user_id: @user.id,
        name:,
        timestamp:
      }
    )
  end

  describe "DST handling" do
    context "when event occurs near midnight during DST" do
      it "correctly attributes event to the right day" do
        user = create(:user, timezone: "Pacific Time (US & Canada)")
        service = described_class.new(user)

        # Event at July 15, 00:30 PDT = July 15, 07:30 UTC
        EsClient.index(
          index: ConfirmedFollowerEvent.index_name,
          body: { followed_user_id: user.id, name: "added", timestamp: Time.utc(2025, 7, 15, 7, 30) }
        )
        ConfirmedFollowerEvent.__elasticsearch__.refresh_index!

        result = service.send(:counts, [Date.new(2025, 7, 14), Date.new(2025, 7, 15)])

        expect(result[:new_followers]).to eq([0, 1])
      end
    end

    context "when query spans DST transition" do
      it "correctly buckets events across DST boundary" do
        user = create(:user, timezone: "Pacific Time (US & Canada)")
        service = described_class.new(user)

        # Event on March 8 at 11:00 PM PST = March 9, 07:00 UTC (before DST starts)
        EsClient.index(
          index: ConfirmedFollowerEvent.index_name,
          body: { followed_user_id: user.id, name: "added", timestamp: Time.utc(2025, 3, 9, 7, 0) }
        )
        # Event on March 10 at 01:00 AM PDT = March 10, 08:00 UTC (after DST starts)
        EsClient.index(
          index: ConfirmedFollowerEvent.index_name,
          body: { followed_user_id: user.id, name: "added", timestamp: Time.utc(2025, 3, 10, 8, 0) }
        )
        ConfirmedFollowerEvent.__elasticsearch__.refresh_index!

        result = service.send(:counts, (Date.new(2025, 3, 8)..Date.new(2025, 3, 10)).to_a)

        expect(result[:new_followers]).to eq([1, 0, 1])
      end
    end
  end
end
