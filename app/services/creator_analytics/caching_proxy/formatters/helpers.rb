# frozen_string_literal: true

module CreatorAnalytics::CachingProxy::Formatters::Helpers
  private
    # When getting data from a mix of cached and uncached sources,
    # `month_index` may not be sequential. This ensures it is the case.
    def rebuild_month_index_values!(dates_and_months)
      last_month = nil
      month_index = -1
      dates_and_months.each do |element|
        if element[:month] != last_month
          last_month = element[:month]
          month_index = month_index + 1
        end
        element[:month_index] = month_index
      end
    end

    def dates_and_months_to_days(dates_and_months, without_years: false)
      dates_and_months.map do |date_data|
        year = Date.parse(date_data[:month]).year
        date = Date.parse("#{date_data[:date]} #{year}")
        day_ordinal = date.day.ordinalize
        new_format = without_years ? "%A, %B #{day_ordinal}" : "%A, %B #{day_ordinal} %Y"
        date.strftime(new_format)
      end
    end

    def dates_and_months_to_months(dates_and_months)
      dates_and_months.map { |date_data| date_data[:month] }.uniq
    end
end
