# frozen_string_literal: true

module CreatorAnalytics::CachingProxy::Formatters::ByState
  # See #merge_data_by_date
  def merge_data_by_state(days_data, _dates = nil)
    data = { by_state: { views: {}, sales: {}, totals: {} } }

    permalinks = days_data.flat_map do |day_data|
      day_data[:by_state].values.flat_map(&:keys)
    end.uniq

    # Every product gets all three series even when a day has no activity for it, and the target
    # hashes are resolved once per product instead of once per product x day x type.
    permalinks.each do |permalink|
      countries_by_type = { views: (data[:by_state][:views][permalink] ||= {}),
                            sales: (data[:by_state][:sales][permalink] ||= {}),
                            totals: (data[:by_state][:totals][permalink] ||= {}) }

      days_data.each do |day_data|
        by_state = day_data[:by_state]
        countries_by_type.each do |type, countries|
          (by_state[type][permalink] || {}).each do |country, value|
            if value.is_a?(Array)
              if (existing = countries[country])
                value.each_with_index { |element, i| existing[i] += element }
              else
                # Copy: the day's array is part of the cached payload and must not be summed into.
                countries[country] = value.dup
              end
            else
              countries[country] = (countries[country] || 0) + value
            end
          end
        end
      end
    end

    data
  end
end
