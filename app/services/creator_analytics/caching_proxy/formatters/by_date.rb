# frozen_string_literal: true

module CreatorAnalytics::CachingProxy::Formatters::ByDate
  # Merges several `#by_date` results into singular data.
  # Does not generate any queries of any kind.
  # Example:
  #   day_1 = Web.new(dates: (monday .. monday).to_a).by_date
  #   day_2 = Web.new(dates: (tuesday .. tuesday).to_a).by_date
  #   day_3 = Web.new(dates: (wednesday .. wednesday).to_a).by_date
  #   merge_data_by_date([day_1, day_2, day_3]) == Web.new(dates: (monday .. wednesday).to_a).by_date
  # Notes:
  # - the days in `days_data` need to be consecutive, and already sorted
  def merge_data_by_date(days_data, _dates = nil)
    data = {
      dates_and_months: [],
      start_date: days_data.first.fetch(:start_date),
      end_date: days_data.last.fetch(:end_date),
      by_date: { views: {}, sales: {}, totals: {} }
    }

    days_data.each do |day_data|
      data[:first_sale_date] = day_data[:first_sale_date] if !data.key?(:first_sale_date) && day_data[:first_sale_date]
      data[:dates_and_months] += day_data[:dates_and_months]
    end
    rebuild_month_index_values!(data[:dates_and_months])

    # We compile all products first,
    # because some products may not have existed in previous days' cached data.
    permalinks = days_data.flat_map do |day_data|
      day_data[:by_date][:views].keys
    end.uniq

    permalinks.each do |permalink|
      days_data.each do |day_data|
        %i[views sales totals].each do |type|
          data[:by_date][type][permalink] ||= []
          if day_data[:by_date][type].key?(permalink)
            data[:by_date][type][permalink] += day_data[:by_date][type][permalink]
          else
            data[:by_date][type][permalink] += [0] * day_data[:dates_and_months].size
          end
        end
      end
    end

    data
  end

  def group_date_data_by_day(data, options = {})
    {
      dates: dates_and_months_to_days(data[:dates_and_months], without_years: options[:days_without_years]),
      by_date: data[:by_date]
    }
  end

  def group_date_data_by_month(data, _options = {})
    months_count = data[:dates_and_months].last[:month_index] + 1
    permalinks = data[:by_date][:views].keys
    products_seed_data = permalinks.index_with { [0] * months_count }

    new_data = {
      dates: dates_and_months_to_months(data[:dates_and_months]),
      by_date: [:views, :sales, :totals].index_with { products_seed_data.deep_dup }
    }

    data[:dates_and_months].each.with_index do |date_data, index|
      %i[views sales totals].each do |type|
        permalinks.each do |permalink|
          new_data[:by_date][type][permalink][date_data[:month_index]] += data[:by_date][type][permalink][index]
        end
      end
    end

    new_data
  end
end
