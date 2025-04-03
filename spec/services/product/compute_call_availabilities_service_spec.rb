# frozen_string_literal: true

require "spec_helper"

describe Product::ComputeCallAvailabilitiesService, :freeze_time do
  let(:seller) { create(:user, :eligible_for_service_products) }
  let(:call_product) { create(:call_product, user: seller) }
  let(:call_limitation_info) { call_product.call_limitation_info }

  let(:service) { described_class.new(call_product) }

  before do
    travel_to(Time.utc(2015, 4, 1))
  end

  def create_call_availability(start_time:, end_time:)
    create(:call_availability, call: call_product, start_time:, end_time:)
  end

  def create_sold_call(start_time:, end_time:)
    create(:call_purchase, link: call_product, call: create(:call, start_time:, end_time:))
  end

  context "when product is not a call product" do
    let(:coffee_product) { create(:coffee_product) }

    it "returns an empty array" do
      expect(service.perform).to eq([])
    end
  end

  it "excludes availabilities from the past" do
    call_limitation_info.update!(minimum_notice_in_minutes: 0)

    create_call_availability(start_time: 10.hours.ago, end_time: 1.hour.from_now)
    create_call_availability(start_time: 1.hour.from_now, end_time: 2.hours.from_now)

    expect(service.perform).to contain_exactly({ start_time: Time.current, end_time: 2.hours.from_now })
  end

  it "excludes availabilities that are within the minimum notice period" do
    call_limitation_info.update!(minimum_notice_in_minutes: 1.hour.in_minutes)

    create_call_availability(start_time: 10.hours.ago, end_time: 2.hours.from_now)

    expect(service.perform).to contain_exactly({ start_time: 1.hour.from_now, end_time: 2.hours.from_now })
  end

  it "excludes availabiltiies on days that exceed the maximum call limit for the seller's timezone" do
    # Explicitly simulate three different timezones to ensure calculations are correct.
    # For ease of understanding, everything is setup in the seller's timezone, and then converted to other timezones
    # as needed.
    seller_timezone = Time.find_zone("Pacific Time (US & Canada)")
    buyer_timezone = Time.find_zone("Eastern Time (US & Canada)")
    system_timezone = Time.find_zone("UTC")

    seller.update!(timezone: seller_timezone.name)
    call_limitation_info.update!(maximum_calls_per_day: 1, minimum_notice_in_minutes: 0)

    travel_to(seller_timezone.local(2015, 4, 1, 12))

    available_from_apr_1_to_apr_6 = create_call_availability(
      start_time: seller_timezone.local(2015, 4, 1, 12),
      end_time: seller_timezone.local(2015, 4, 6, 12)
    )
    create_sold_call(
      start_time: seller_timezone.local(2015, 4, 2, 12).in_time_zone(buyer_timezone),
      end_time: seller_timezone.local(2015, 4, 2, 13).in_time_zone(buyer_timezone)
    )
    create_sold_call(
      start_time: seller_timezone.local(2015, 4, 3, 12).in_time_zone(buyer_timezone),
      end_time: seller_timezone.local(2015, 4, 3, 13).in_time_zone(buyer_timezone)
    )
    sold_apr_5_to_apr_6 = create_sold_call(
      start_time: seller_timezone.local(2015, 4, 5, 12).in_time_zone(buyer_timezone),
      end_time: seller_timezone.local(2015, 4, 6, 1).in_time_zone(buyer_timezone)
    )

    availabilities = Time.use_zone(system_timezone) { service.perform }
    expect(availabilities).to contain_exactly(
      {
        start_time: available_from_apr_1_to_apr_6.start_time,
        # Apr 2nd has already scheduled the maximum number of calls, thus available till the end of Apr 1st.
        end_time: seller_timezone.local(2015, 4, 1).end_of_day
      },
      {
        # Apr 3rd has already scheduled the maximum number of calls, thus available from the beginning of Apr 4th.
        start_time: seller_timezone.local(2015, 4, 4).beginning_of_day,
        # Apr 5th has already scheduled the maximum number of calls, thus available till the end of Apr 4th.
        end_time: seller_timezone.local(2015, 4, 4).end_of_day
      },
      {
        # The call that spans from Apr 5th to 6th does not count towards limit for Apr 6th, thus available from Apr 6th.
        start_time: sold_apr_5_to_apr_6.call.end_time,
        end_time: available_from_apr_1_to_apr_6.end_time
      }
    )
  end

  it "excludes availabilities that are sold" do
    # Ensure overlapping availabilities are not double counted.
    create_call_availability(start_time: 10.hours.from_now, end_time: 16.hours.from_now)
    create_call_availability(start_time: 10.hours.from_now, end_time: 16.hours.from_now)

    create_sold_call(start_time: 9.hours.from_now, end_time: 11.hours.from_now)
    create_sold_call(start_time: 14.hours.from_now, end_time: 15.hours.from_now)

    expect(service.perform).to contain_exactly(
      { start_time: 11.hours.from_now, end_time: 14.hours.from_now },
      { start_time: 15.hours.from_now, end_time: 16.hours.from_now }
    )
  end

  it "includes availabilities that are sold but no longer take up availabilities" do
    create_call_availability(start_time: 10.hours.from_now, end_time: 16.hours.from_now)

    create(
      :call_purchase,
      :refunded,
      link: call_product,
      call: create(:call, start_time: 10.hours.from_now, end_time: 11.hours.from_now)
    )
    create(
      :call_purchase,
      purchase_state: "failed",
      link: call_product,
      call: create(:call, start_time: 11.hours.from_now, end_time: 12.hours.from_now)
    )

    expect(service.perform).to contain_exactly({ start_time: 10.hours.from_now, end_time: 16.hours.from_now })
  end
end
