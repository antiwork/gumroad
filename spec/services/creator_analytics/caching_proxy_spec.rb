# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::CachingProxy do
  describe "#data_for_dates" do
    before do
      @user = create(:user, timezone: "London", created_at: Time.utc(2019, 1, 1))
      travel_to Time.utc(2020, 1, 1)
      @product = create(:product, user: @user)
      @dates = (Date.new(2019, 1, 30) .. Date.new(2019, 2, 5)).to_a
      @service = described_class.new(@user)
      recreate_model_index(ProductPageView)
      recreate_model_index(Purchase)
    end

    def web_data(by, start_date, end_date)
      CreatorAnalytics::Web.new(user: @user, dates: (start_date .. end_date).to_a).public_send("by_#{by}")
    end

    it "returns merged mix of cached and generated data" do
      allow(@service).to receive(:use_cache?).and_return(true)

      [:date, :state, :referral].each do |by|
        # create data for some days, not others
        @dates.values_at(0, 3, 6).each do |date|
          create(:computed_sales_analytics_day,
                 key: @service.send(:cache_key_for_data, date, by:),
                 data: web_data(by, date, date).to_json
          )
        end

        # check that the two missing date ranges are generated dynamically
        expect(@service).to receive(:analytics_data).with(@dates[1], @dates[2], by:).and_call_original
        expect(@service).to receive(:analytics_data).with(@dates[4], @dates[5], by:).and_call_original
        if by == :date
          expect(@service).to receive(:rebuild_month_index_values!).and_call_original
        end

        expect(@service).to receive("merge_data_by_#{by}").and_call_original

        result = @service.data_for_dates(@dates.first, @dates.last, by:)
        original_method_result = web_data(by, @dates.first, @dates.last)
        expect(result).to equal_with_indifferent_access(original_method_result)
      end
    end

    it "can generate grouped data, by day and month" do
      @user.update!(timezone: "UTC") # timezones considerations are not relevant here
      dates = @dates[0 .. 2] # we only need 3 days, crossing 2 months, to test this
      products = [@product, create(:product, user: @user)]
      permalinks = products.map(&:unique_permalink)
      dates.each do |date|
        create(:purchase, link: products.first, created_at: date)
        add_page_view(products.first, date)
      end
      ProductPageView.__elasticsearch__.refresh_index!
      index_model_records(Purchase)

      expect(@service.data_for_dates(dates.first, dates.last, by: :date, options: { group_by: :day })).to eq(
        dates: ["Wednesday, January 30th 2019", "Thursday, January 31st 2019", "Friday, February 1st 2019"],
        by_date: {
          views: { permalinks[0] => [1, 1, 1], permalinks[1] => [0, 0, 0] },
          sales: { permalinks[0] => [1, 1, 1], permalinks[1] => [0, 0, 0] },
          totals: { permalinks[0] => [100, 100, 100], permalinks[1] => [0, 0, 0] }
        }
      )
      expect(@service.data_for_dates(dates.first, dates.last, by: :date, options: { group_by: :month })).to eq(
        dates: ["January 2019", "February 2019"],
        by_date: {
          views: { permalinks[0] => [2, 1], permalinks[1] => [0, 0] },
          sales: { permalinks[0] => [2, 1], permalinks[1] => [0, 0] },
          totals: { permalinks[0] => [200, 100], permalinks[1] => [0, 0] }
        }
      )
      expect(@service.data_for_dates(dates.first, dates.last, by: :referral, options: { group_by: :day })).to eq(
        dates: ["Wednesday, January 30th 2019", "Thursday, January 31st 2019", "Friday, February 1st 2019"],
        by_referral: {
          views: { permalinks[0] => { "direct" => [1, 1, 1] } },
          sales: { permalinks[0] => { "direct" => [1, 1, 1] } },
          totals: { permalinks[0] => { "direct" => [100, 100, 100] } }
        }
      )
      expect(@service.data_for_dates(dates.first, dates.last, by: :referral, options: { group_by: :month })).to eq(
        dates: ["January 2019", "February 2019"],
        by_referral: {
          views: { permalinks[0] => { "direct" => [2, 1] } },
          sales: { permalinks[0] => { "direct" => [2, 1] } },
          totals: { permalinks[0] => { "direct" => [200, 100] } }
        }
      )
    end

    it "calls original method if cache shouldn't be used" do
      allow(@service).to receive(:use_cache?).and_return(false)
      expect(@service).not_to receive(:fetch_data_for_dates)
      expect(@service).to receive(:analytics_data).with(@dates.first, @dates.last, by: :date).and_call_original

      @service.data_for_dates(@dates.first, @dates.last, by: :date)
    end
  end

  describe "#generate_cache" do
    it "generates the cached data for all non-existent days of activity of users" do
      product = create(:product)
      service = described_class.new(product.user)

      # 10pm@UTC is always day+1@Tokyo:
      # Setting this shows that we're not generating cache for the 1st of August, but for the 2nd,
      # which is the first day of sales in the seller's time zone.
      product.user.update!(timezone: "Tokyo")
      create(:purchase, link: product, created_at: Time.utc(2020, 8, 1, 22))
      create(:purchase, link: product, created_at: Time.utc(2020, 8, 3))

      # 10pm@UTC is always day+1@Tokyo:
      # This results in "Today" in Tokyo being the 7th of August.
      travel_to Time.utc(2020, 8, 6, 22)

      # Generate a day in the cache, will show that we're not generating cache for existing cache day
      create(:computed_sales_analytics_day, key: service.send(:cache_key_for_data, Date.new(2020, 8, 4), by: :date), data: "{}")
      create(:computed_sales_analytics_day, key: service.send(:cache_key_for_data, Date.new(2020, 8, 3), by: :state), data: "{}")
      create(:computed_sales_analytics_day, key: service.send(:cache_key_for_data, Date.new(2020, 8, 5), by: :referral), data: "{}")

      # by date
      expect(service).to receive(:fetch_data).with(Date.new(2020, 8, 2), by: :date)
      expect(service).to receive(:fetch_data).with(Date.new(2020, 8, 3), by: :date)
      # The 4th of August for date isn't generated because it already exists
      expect(service).to receive(:fetch_data).with(Date.new(2020, 8, 5), by: :date)

      # by state
      expect(service).to receive(:fetch_data).with(Date.new(2020, 8, 2), by: :state)
      # The 3rd of August for state isn't generated because it already exists
      expect(service).to receive(:fetch_data).with(Date.new(2020, 8, 4), by: :state)
      expect(service).to receive(:fetch_data).with(Date.new(2020, 8, 5), by: :state)

      # by referral
      expect(service).to receive(:fetch_data).with(Date.new(2020, 8, 2), by: :referral)
      expect(service).to receive(:fetch_data).with(Date.new(2020, 8, 3), by: :referral)
      expect(service).to receive(:fetch_data).with(Date.new(2020, 8, 4), by: :referral)
      # The 5th of August for referral isn't generated because it already exists

      service.generate_cache
    end

    it "handles users with no sales" do
      user = create(:user)
      expect { described_class.new(user).generate_cache }.not_to raise_error
    end

    it "skips suspended users" do
      user = create(:tos_user)
      create(:purchase, link: create(:product, user:))
      expect(user).not_to receive(:sales)
      described_class.new(user).generate_cache
    end
  end

  describe "#overwrite_cache" do
    before do
      travel_to Time.utc(2020, 1, 1)
      @user = create(:user, timezone: "London")
      @service = described_class.new(@user)
    end

    it "does not update data for yesterday, today, or any day after" do
      allow(@service).to receive(:use_cache?).and_return(true)
      expect(ComputedSalesAnalyticsDay).not_to receive(:upsert_data_from_key)
      @service.overwrite_cache(Date.yesterday)
      @service.overwrite_cache(Date.today)
      @service.overwrite_cache(Date.tomorrow)
      @service.overwrite_cache(Date.tomorrow + 1)
    end

    it "does not update data for days before analytics were generated" do
      allow(@service).to receive(:use_cache?).and_return(true)
      expect(ComputedSalesAnalyticsDay).not_to receive(:upsert_data_from_key)
      @service.overwrite_cache(Date.new(2012, 9, 1))
    end

    it "does not update data when cache should not be used" do
      allow(@service).to receive(:use_cache?).and_return(false)
      expect(ComputedSalesAnalyticsDay).not_to receive(:upsert_data_from_key)
      @service.overwrite_cache(Date.yesterday)
    end

    it "regenerates and stores analytics for the date" do
      allow(@service).to receive(:use_cache?).and_return(true)
      date = 2.days.ago.to_date
      # generate data
      @service.send(:fetch_data, date)
      expect(@service.send(:fetch_data, date)).to equal_with_indifferent_access(@service.send(:analytics_data, date, date))
      # add a page view
      add_page_view(create(:product, user: @user), date)
      ProductPageView.__elasticsearch__.refresh_index!
      # check that the stored data is indeed different than freshly generated data
      expect(@service.send(:fetch_data, date)).not_to equal_with_indifferent_access(@service.send(:analytics_data, date, date))
      # overwrite cached data
      @service.overwrite_cache(date)
      # check that the stored data is now the same than freshly generated data
      expect(@service.send(:fetch_data, date)).to equal_with_indifferent_access(@service.send(:analytics_data, date, date))
    end
  end

  describe "#use_cache?" do
    it "returns true if user is a large seller" do
      user = create(:user)
      service = described_class.new(user)
      expect(service.send(:use_cache?)).to eq(false)

      create(:large_seller, user:)
      expect(service.send(:use_cache?)).to eq(true)
    end
  end

  describe "#cache_key_for_data" do
    it "returns cache key for data by date" do
      user = create(:user, timezone: "Rome")
      cache_key = described_class.new(user).send(:cache_key_for_data, Date.new(2020, 12, 3))
      expect(cache_key).to eq("seller_analytics_v0_user_#{user.id}_Rome_by_date_for_2020-12-03")
    end
  end

  describe "#user_cache_key" do
    it "returns cache key for the user and its timezone" do
      user = create(:user, timezone: "Paris")
      user_cache_key = described_class.new(user).send(:user_cache_key)
      expect(user_cache_key).to eq("seller_analytics_v0_user_#{user.id}_Paris")

      $redis.set(RedisKey.seller_analytics_cache_version, 3)
      user_cache_key = described_class.new(user).send(:user_cache_key)
      expect(user_cache_key).to eq("seller_analytics_v3_user_#{user.id}_Paris")
    end
  end

  describe "#analytics_data" do
    it "proxies method call to user" do
      user = create(:user, timezone: "London")
      start_date, end_date = Date.new(2019, 1, 1), Date.new(2019, 1, 7)
      dates = (start_date .. end_date).to_a
      expect(CreatorAnalytics::Web).to receive(:new).with(user:, dates:).thrice.and_call_original
      expect_any_instance_of(CreatorAnalytics::Web).to receive(:by_date).and_call_original
      expect_any_instance_of(CreatorAnalytics::Web).to receive(:by_state).and_call_original
      expect_any_instance_of(CreatorAnalytics::Web).to receive(:by_referral).and_call_original

      service = described_class.new(user)
      service.send(:analytics_data, start_date, end_date, by: :date)
      service.send(:analytics_data, start_date, end_date, by: :state)
      service.send(:analytics_data, start_date, end_date, by: :referral)
    end
  end

  describe "#fetch_data" do
    before do
      # We need to a known point in time to avoid DST issues when running tests.
      travel_to Time.utc(2020, 2, 1)
      @user = create(:user, timezone: "London")
      @service = described_class.new(@user)
    end

    it "returns cached data if it exists, generates the data if not" do
      date = Date.new(2020, 1, 1)
      expect(@service).to receive(:analytics_data).with(date, date, by: :date).once.and_return("foo")
      expect(@service.send(:fetch_data, date)).to eq("foo")
      expect(@service.send(:fetch_data, date)).to eq("foo") # from cache
    end

    it "does not cache the data if the date is yesterday, today, or any day after" do
      date = Date.new(2020, 2, 1)
      expect(ComputedSalesAnalyticsDay).not_to receive(:fetch_data_from_key)
      expect(@service).to receive(:analytics_data).with(date - 1, date - 1, by: :date).twice.and_return("foo", "bar")
      expect(@service).to receive(:analytics_data).with(date, date, by: :date).twice.and_return("baz", "qux")
      expect(@service).to receive(:analytics_data).with(date + 1, date + 1, by: :date).and_return("quux")
      expect(@service.send(:fetch_data, date - 1)).to eq("foo")
      expect(@service.send(:fetch_data, date - 1)).to eq("bar")
      expect(@service.send(:fetch_data, date)).to eq("baz")
      expect(@service.send(:fetch_data, date)).to eq("qux")
      expect(@service.send(:fetch_data, date + 1)).to eq("quux")
    end
  end

  describe "#uncached_dates" do
    it "returns all dates missing from cache" do
      user = create(:user)
      service = described_class.new(user)

      [Date.new(2020, 1, 1), Date.new(2020, 1, 3)].each do |date|
        create(:computed_sales_analytics_day, key: service.send(:cache_key_for_data, date), data: "{}")
      end

      dates = (Date.new(2020, 1, 1) .. Date.new(2020, 1, 4)).to_a
      expect(service.send(:uncached_dates, dates)).to match_array([
                                                                    Date.new(2020, 1, 2),
                                                                    Date.new(2020, 1, 4)
                                                                  ])
    end
  end

  describe "#requested_dates" do
    before do
      @user = create(:user, timezone: "London", created_at: Time.utc(2019))
      travel_to Time.utc(2020)
      @service = described_class.new(@user)
      described_class.send(:public, :requested_dates)
    end

    it "constrains start and end dates to a maximum of Today" do
      expect(@service.requested_dates(Date.today + 2, Date.today + 5)).to eq([Date.today])
    end

    it "constrains start date to a minimum of the user creation date" do
      # when requested dates span from the past to the future
      expect(@service.requested_dates(Date.new(1998), Date.today + 5)).to eq((Date.new(2019) .. Date.today).to_a)
      # when requested dates are all in the past
      expect(@service.requested_dates(Date.new(1998), Date.new(1999))).to eq([Date.new(2019)])
      # when requested start date is greater than the user creation date, the constrained start is the same
      expect(@service.requested_dates(Date.new(2019, 5), Date.new(2019, 6)).first).to eq(Date.new(2019, 5))
    end

    it "returns the correct array when the dates are valid" do
      expect(@service.requested_dates(Date.today - 5, Date.today - 3)).to eq((Date.today - 5 .. Date.today - 3).to_a)
      expect(@service.requested_dates(Date.today - 5, Date.today)).to eq((Date.today - 5 .. Date.today).to_a)
      expect(@service.requested_dates(Date.today - 5, Date.today - 5)).to eq([Date.today - 5])
      expect(@service.requested_dates(Date.today, Date.today)).to eq([Date.today])
    end

    it "handles nonsensical requested dates" do
      # when end_date < start_date, returns the end date
      expect(@service.requested_dates(Date.today - 5, Date.today - 10)).to eq([Date.today - 5])
      # when end_date < start_date AND both of them are before the user creation date, returns the user creation date
      expect(@service.requested_dates(@user.created_at.to_date - 5, @user.created_at.to_date - 10)).to eq([@user.created_at.to_date])
      # when end_date < start_date AND start date is in the future, return that date
      expect(@service.requested_dates(@user.created_at.to_date + 1, @user.created_at.to_date - 10)).to eq([@user.created_at.to_date + 1])
    end

    it "returns at least a date whatever dates were requested" do
      expect(@service.requested_dates(100.years.ago, 50.years.ago)).not_to be_empty
      expect(@service.requested_dates(50.years.from_now, 100.years.from_now)).not_to be_empty
      expect(@service.requested_dates(100.years.ago, 100.years.from_now)).not_to be_empty
    end
  end

  describe "#fetch_data_for_dates" do
    before do
      @user = create(:user, timezone: "London")
      @service = described_class.new(@user)
    end

    it "returns a hash with the stored values" do
      dates = [Date.new(2020, 9, 1), Date.new(2020, 9, 2)]
      ComputedSalesAnalyticsDay.upsert_data_from_key(
        @service.send(:cache_key_for_data, dates[0], by: :date),
        { "foo" => "bar" }
      )

      expect(@service.send(:fetch_data_for_dates, dates)).to eq(
        dates[0] => { "foo" => "bar" },
        dates[1] => nil
      )
    end
  end

  describe "#compile_data_for_dates_and_fill_missing" do
    before do
      @user = create(:user)
      @service = described_class.new(@user)
    end

    it "returns array of data for all days, including missing" do
      expect(@service).to receive(:analytics_data).with(
        Date.new(2020, 1, 2),
        Date.new(2020, 1, 3),
        by: :date
      ).and_return("data-for-day-two-and-three" => :bar)

      result = @service.send(:compile_data_for_dates_and_fill_missing,
                             {
                               Date.new(2020, 1, 1) => { "data-for-day-one" => :foo },
                               Date.new(2020, 1, 2) => nil,
                               Date.new(2020, 1, 3) => nil,
                             },
                             by: :date
      )

      expect(result).to eq([
                             { "data-for-day-one" => :foo },
                             { "data-for-day-two-and-three" => :bar }
                           ])
    end
  end

  describe "#find_missing_date_ranges" do
    before do
      @service = described_class.new(build(:user))
    end

    it "contiguous missing dates as ranges" do
      result = @service.send(:find_missing_date_ranges,
                             Date.new(2020, 1, 1) => nil,
                             Date.new(2020, 1, 2) => nil,
                             Date.new(2020, 1, 3) => "data",
                             Date.new(2020, 1, 4) => nil,
                             Date.new(2020, 1, 5) => "data",
                             Date.new(2020, 1, 6) => nil,
                             Date.new(2020, 1, 7) => nil,
                             Date.new(2020, 1, 8) => nil,
      )

      expect(result).to eq([
                             Date.new(2020, 1, 1) .. Date.new(2020, 1, 2),
                             Date.new(2020, 1, 4) .. Date.new(2020, 1, 4),
                             Date.new(2020, 1, 6) .. Date.new(2020, 1, 8)
                           ])
    end
  end
end
