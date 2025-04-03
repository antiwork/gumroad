# frozen_string_literal: true

module Mongoable
  def time_fields
    raise NotImplementedError
  end

  def to_mongo
    attributes_to_save = attributes
    attributes_to_save["updated_at"] = Time.current

    time_fields.each do |field|
      attributes_to_save[field] = send(field.to_sym).utc.to_time if send(field.to_sym).present?
    end

    Mongoer.async_write(self.class.to_s, JSON.parse(JSON.dump(attributes_to_save)))
  end

  # Public: Returns a mongo query to get the history of this record as stored in the mongo database.
  # Call `one` on the result of this function to get the first, or `limit(...)` to set the limit and
  # `to_a` to get all the results. Use `sort(field: 1 or -1)` to sort.
  def history
    MONGO_DATABASE[self.class.to_s].find("id" => id)
  end
end
