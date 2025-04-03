# frozen_string_literal: true

class Mongoer
  def self.substitute_keys(hash)
    hash.keys.each do |key|
      if hash[key].is_a? Hash
        substitute_keys(hash[key])
      elsif hash[key].is_a? Array
        hash[key].each do |element|
          substitute_keys(element) if element.is_a? Hash
        end
      end

      if key.to_s.index(/\.|\$/).present?
        hash[key.to_s.gsub(".", "U+FFOE").gsub("$", "U+FF04")] = hash[key]
        hash.delete(key)
      end
    end
  end

  def self.safe_write(collection, doc)
    substitute_keys(doc)
    MONGO_DATABASE[collection].insert_one(doc)
  end

  def self.safe_update(collection, conditions, doc)
    substitute_keys(doc)
    MONGO_DATABASE[collection].find(conditions).update_one("$set" => doc)
  end

  def self.async_write(collection, doc)
    SaveToMongoWorker.perform_async(collection, doc)
  rescue Encoding::UndefinedConversionError => e
    Rails.logger.error("Encoding::UndefinedConversionError queueing SaveToMongo for collection #{collection}\nwith error:\n#{e.inspect}\nwith doc:\n#{doc}")
  end

  def self.async_update(collection, conditions, doc)
    UpdateInMongoWorker.perform_async(collection, conditions, doc)
  end
end
