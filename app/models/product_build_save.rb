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
  MAX_WRITER_ID_LENGTH = 32
  MAX_SEQUENCE = 2**53 - 1
  # Writers are page loads, so only the most recent ones can still have a batch on its way.
  MAX_TRACKED_CLEARS = 20
  WRITER_ID_FORMAT = /\A[A-Za-z0-9]{1,#{MAX_WRITER_ID_LENGTH}}\z/

  belongs_to :purchase

  attribute :data, :json, default: -> { {} }
  # Which batch last changed each key, "keys" => { key => [writer, sequence] }, and each writer's last
  # clear, "clears" => [[writer, sequence], ...] oldest first (an array, because MySQL does not keep
  # JSON object keys in order). A removed key keeps its entry, so a late batch cannot bring it back.
  attribute :key_versions, :json, default: -> { { "keys" => {}, "clears" => [] } }

  # Clears first, then removes, then sets, so one batch can replace the whole save.
  #
  # `writer` names one page load of the player and `sequence` numbers its batches. Batches can reach
  # the server out of order (a retry, a beacon sent as the page closes), so the order is kept per key:
  # a change is skipped when a later batch from the same writer already changed that key, or cleared
  # the save. The rest of a late batch still applies. Batches from different page loads apply in
  # arrival order: the last write wins.
  def self.apply_changes!(purchase, set: {}, remove: [], clear: false, writer: nil, sequence: nil)
    validate_changes!(set, remove, clear)
    validate_writer!(writer, sequence)

    save = create_or_find_by!(purchase:)
    save.with_lock do
      data = save.data.dup
      versions = { "keys" => {}, "clears" => [] }.merge(save.key_versions || {})
      key_versions = versions["keys"].dup
      clears = versions["clears"].dup
      cleared_after = writer && clears.find { |name, _| name == writer }&.last.to_i > sequence
      stale = ->(key) do
        next false unless writer
        next true if cleared_after

        last_writer, last_sequence = key_versions[key]
        last_writer == writer && last_sequence > sequence
      end
      change = ->(key) { key_versions[key] = [writer, sequence] if writer }

      if clear && !cleared_after
        data.keys.each do |key|
          next if stale.(key)

          data.delete(key)
          change.(key)
        end
        if writer
          clears.reject! { |name, _| name == writer }
          clears << [writer, sequence]
          clears.shift while clears.size > MAX_TRACKED_CLEARS
        end
      end
      remove.each do |key|
        next if stale.(key)

        data.delete(key)
        change.(key)
      end
      set.each do |key, value|
        next if stale.(key)

        data[key] = value
        change.(key)
      end

      byte_size = data.sum { |key, value| key.bytesize + value.bytesize }
      raise LimitError, "A save can hold at most #{MAX_KEYS} keys." if data.size > MAX_KEYS
      raise LimitError, "A save can hold at most #{MAX_BYTE_SIZE / 1.megabyte} MB." if byte_size > MAX_BYTE_SIZE

      # Removed keys' entries are kept to stop a late batch bringing them back, up to a bound.
      removed = key_versions.keys - data.keys
      removed.first(key_versions.size - MAX_KEYS * 2).each { key_versions.delete(_1) } if key_versions.size > MAX_KEYS * 2
      save.update!(data:, byte_size:, key_versions: { "keys" => key_versions, "clears" => clears })
    end
    save
  end

  def self.validate_changes!(set, remove, clear)
    unless set.is_a?(Hash) && remove.is_a?(Array) && [true, false].include?(clear)
      raise LimitError, "A batch needs `set` as an object, `remove` as a list, and `clear` as true or false."
    end

    keys = set.keys + remove
    raise LimitError, "Keys and values must be strings." unless keys.all?(String) && set.values.all?(String)
    # MySQL rejects a JSON document that is not valid UTF-8, which a lone surrogate from JavaScript becomes.
    raise LimitError, "Keys and values must be valid UTF-8." unless (keys + set.values).all?(&:valid_encoding?)
    raise LimitError, "A key can be at most #{MAX_KEY_BYTES} bytes." if keys.any? { _1.bytesize > MAX_KEY_BYTES }
  end

  def self.validate_writer!(writer, sequence)
    return if writer.nil? && sequence.nil?
    return if writer.is_a?(String) && writer.match?(WRITER_ID_FORMAT) && sequence.is_a?(Integer) && sequence.between?(1, MAX_SEQUENCE)

    raise LimitError, "A batch needs `writer` as up to #{MAX_WRITER_ID_LENGTH} letters and digits, and `sequence` as a positive whole number."
  end
  private_class_method :validate_changes!, :validate_writer!
end
