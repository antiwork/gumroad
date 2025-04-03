# frozen_string_literal: true

module PreorderHelper
  def displayable_release_at_date(release_at, seller_timezone)
    release_at_seller_time = release_at_seller_time(release_at, seller_timezone)
    release_at_seller_time.to_fs(:formatted_date_full_month)
  end

  def displayable_release_at_time(release_at, seller_timezone)
    release_at_seller_time = release_at_seller_time(release_at, seller_timezone)
    minute = release_at_seller_time.strftime("%M")
    minute == "00" ? release_at_seller_time.strftime("%l%p") : release_at_seller_time.strftime("%l:%M%p")
  end

  def displayable_release_at_date_and_time(release_at, seller_timezone)
    release_at_seller_time = release_at_seller_time(release_at, seller_timezone)
    short_timezone = release_at_short_timezone(release_at, seller_timezone)
    minute = release_at_seller_time.strftime("%M")
    if minute == "00"
      release_at_seller_time.strftime("%B #{release_at_seller_time.day.ordinalize}, %l%p #{short_timezone}")
    else
      release_at_seller_time.strftime("%B #{release_at_seller_time.day.ordinalize}, %l:%M%p #{short_timezone}")
    end
  end

  def release_at_seller_time(release_at, seller_timezone)
    timezone = ActiveSupport::TimeZone[seller_timezone]
    time = timezone.tzinfo.utc_to_local(release_at)
    Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec, time.sec_fraction * 1_000_000)
  end

  def short_timezone(timezone)
    ActiveSupport::TimeZone[timezone].now.strftime("%Z")
  end

  def release_at_short_timezone(release_at, seller_timezone)
    Time.zone.parse(release_at.to_s).in_time_zone(seller_timezone).strftime("%Z")
  end
end
