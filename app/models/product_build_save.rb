# frozen_string_literal: true

# A buyer's saved progress in a product's web build: one string-to-string map per purchase, the
# shape of localStorage. It belongs to the purchase, not to a build, so a save survives the seller
# promoting a new build. The player's storage shims read the whole map on load and send changes in
# batches, so a batch is applied as one write under a row lock.
class ProductBuildSave < ApplicationRecord
  class LimitError < StandardError; end

  MAX_KEY_BYTES = 1.kilobyte
  MAX_KEYS = 1_000
  # About the localStorage quota browsers give one origin, which is what the games were written for.
  MAX_BYTE_SIZE = 5.megabytes

  belongs_to :purchase

  attribute :data, :json, default: -> { {} }

  # Clears first, then removes, then sets, so one batch can replace the whole save.
  def self.apply_changes!(purchase, set: {}, remove: [], clear: false)
    validate_changes!(set, remove)

    save = create_or_find_by!(purchase:)
    save.with_lock do
      data = clear ? {} : save.data.dup
      remove.each { data.delete(_1) }
      data.merge!(set)

      byte_size = data.sum { |key, value| key.bytesize + value.bytesize }
      raise LimitError, "A save can hold at most #{MAX_KEYS} keys." if data.size > MAX_KEYS
      raise LimitError, "A save can hold at most #{MAX_BYTE_SIZE / 1.megabyte} MB." if byte_size > MAX_BYTE_SIZE

      save.update!(data:, byte_size:)
    end
    save
  end

  def self.validate_changes!(set, remove)
    keys = set.keys + remove
    raise LimitError, "Keys and values must be strings." unless keys.all?(String) && set.values.all?(String)
    # MySQL rejects a JSON document that is not valid UTF-8, which a lone surrogate from JavaScript becomes.
    raise LimitError, "Keys and values must be valid UTF-8." unless (keys + set.values).all?(&:valid_encoding?)
    raise LimitError, "A key can be at most #{MAX_KEY_BYTES} bytes." if keys.any? { _1.bytesize > MAX_KEY_BYTES }
  end
  private_class_method :validate_changes!
end
