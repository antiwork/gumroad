# frozen_string_literal: true

module CreatorAnalytics::CachingProxy::Formatters::ByState
  # See #merge_data_by_date
  def merge_data_by_state(days_data, _dates = nil)
    data = { by_state: { views: {}, sales: {}, totals: {} } }

    permalinks = days_data.flat_map do |day_data|
      day_data[:by_state].values.map(&:keys)
    end.flatten.uniq


    permalinks.each do |permalink|
      days_data.each do |day_data|
        %i[views sales totals].each do |type|
          data[:by_state][type][permalink] ||= {}
          (day_data[:by_state][type][permalink] || {}).each do |country, value|
            if value.is_a?(Array)
              if data[:by_state][type][permalink].key?(country)
                value.each.with_index do |element, i|
                  data[:by_state][type][permalink][country][i] += element
                end
              else
                data[:by_state][type][permalink][country] = value
              end
            else
              data[:by_state][type][permalink][country] ||= 0
              data[:by_state][type][permalink][country] += value
            end
          end
        end
      end
    end

    data
  end
end
