# frozen_string_literal: true

module CreatorAnalytics::CachingProxy::Formatters::ByReferral
  # See #merge_data_by_date
  def merge_data_by_referral(days_data, dates)
    data = { by_referral: { views: {}, sales: {}, totals: {} } }

    # We compile all products first,
    # because some products may not have existed in previous days' cached data.
    permalinks = days_data.flat_map do |day_data|
      day_data[:by_referral].values.map(&:keys)
    end.flatten.uniq

    # Compile referrers by type and product
    referrers = {}
    %i[views sales totals].each do |type|
      referrers[type] ||= {}
      permalinks.each do |permalink|
        referrers[type][permalink] ||= []
        days_data.each do |day_data|
          referrers[type][permalink] += day_data.dig(:by_referral, type, permalink)&.keys || []
        end
        referrers[type][permalink].uniq!
      end
    end

    permalinks.each do |permalink|
      total_day_index = 0
      days_data.each do |day_data|
        %i[views sales totals].each do |type|
          data[:by_referral][type][permalink] ||= {}
          referrers[type][permalink].each do |referrer|
            data[:by_referral][type][permalink][referrer] ||= [0] * dates.size
            data[:by_referral][type][permalink][referrer][total_day_index .. (total_day_index + day_data[:dates_and_months].size - 1)] = (day_data.dig(:by_referral, type, permalink, referrer) || ([0] * day_data[:dates_and_months].size))
          end
        end
        total_day_index += day_data[:dates_and_months].size
      end
    end

    data[:dates_and_months] = D3.date_month_domain(dates.first .. dates.last)
    data[:start_date] = D3.formatted_date(dates.first)
    data[:end_date] = D3.formatted_date(dates.last)
    first_sale_created_at = @user.first_sale_created_at_for_analytics
    data[:first_sale_date] = D3.formatted_date_with_timezone(first_sale_created_at, @user.timezone) if first_sale_created_at

    data
  end

  def group_referral_data_by_day(data, options = {})
    {
      dates: dates_and_months_to_days(data[:dates_and_months], without_years: options[:days_without_years]),
      by_referral: data[:by_referral]
    }
  end

  def group_referral_data_by_month(data, _options = {})
    months_count = data[:dates_and_months].last[:month_index] + 1
    permalinks = (data[:by_referral][:views].keys + data[:by_referral][:sales].keys + data[:by_referral][:totals].keys).uniq
    products_seed_data = [:views, :sales, :totals].index_with do |type|
      data[:by_referral][type].keys.index_with do |key|
        data[:by_referral][type][key].transform_values do
          [0] * months_count
        end
      end
    end

    new_data = {
      dates: dates_and_months_to_months(data[:dates_and_months]),
      by_referral: products_seed_data
    }

    data[:dates_and_months].each.with_index do |date_data, index|
      %i[views sales totals].each do |type|
        permalinks.each do |permalink|
          (data[:by_referral][type][permalink] || {}).keys.each do |referrer|
            new_data[:by_referral][type][permalink][referrer][date_data[:month_index]] += data[:by_referral][type][permalink][referrer][index]
          end
        end
      end
    end

    new_data
  end
end
