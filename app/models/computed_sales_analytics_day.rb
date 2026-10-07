# frozen_string_literal: true

class ComputedSalesAnalyticsDay < ApplicationRecord
  def self.read_data_from_keys(keys)
    with_empty_values = keys.zip([nil]).to_h
    with_existing_values = where(key: keys).order(:key).pluck(:key, :data).to_h do |(key, data)|
      [key, JSON.parse(data)]
    end
    with_empty_values.merge(with_existing_values)
  end

  def self.fetch_data_from_key(key)
    record = find_by(key:)
    return JSON.parse(record.data) if record

    # Callers query Elasticsearch, so compute before the creation transaction.
    data = yield.to_json
    record = create_or_find_by!(key:) { |entry| entry.data = data }
    JSON.parse(record.data)
  end

  def self.upsert_data_from_key(key, data)
    serialized_data = data.to_json
    record = find_by(key:) || create_or_find_by!(key:) { |entry| entry.data = serialized_data }
    record.update!(data: serialized_data)
    record
  end
end
