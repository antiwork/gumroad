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
  MAX_TRACKED_WRITERS = 20
  WRITER_ID_FORMAT = /\A[A-Za-z0-9]{1,#{MAX_WRITER_ID_LENGTH}}\z/

  belongs_to :purchase

  attribute :data, :json, default: -> { {} }
  # [writer, sequence] pairs, oldest first. An array, because MySQL does not keep JSON object keys in order.
  attribute :writer_sequences, :json, default: -> { [] }

  # Clears first, then removes, then sets, so one batch can replace the whole save.
  #
  # `writer` names one page load of the player and `sequence` numbers its batches. A batch can reach
  # the server after a newer one from the same page (a retry, or a beacon sent as the page closes),
  # so a batch at or below the last sequence applied for that writer is skipped, whatever other
  # writers did in between. Batches from different page loads apply in arrival order: the last write wins.
  def self.apply_changes!(purchase, set: {}, remove: [], clear: false, writer: nil, sequence: nil)
    validate_changes!(set, remove, clear)
    validate_writer!(writer, sequence)

    save = create_or_find_by!(purchase:)
    save.with_lock do
      sequences = Array(save.writer_sequences).reject { |name, _| name == writer }
      last_sequence = Array(save.writer_sequences).find { |name, _| name == writer }&.last
      next if writer && last_sequence && sequence <= last_sequence

      data = clear ? {} : save.data.dup
      remove.each { data.delete(_1) }
      data.merge!(set)

      byte_size = data.sum { |key, value| key.bytesize + value.bytesize }
      raise LimitError, "A save can hold at most #{MAX_KEYS} keys." if data.size > MAX_KEYS
      raise LimitError, "A save can hold at most #{MAX_BYTE_SIZE / 1.megabyte} MB." if byte_size > MAX_BYTE_SIZE

      if writer
        sequences << [writer, sequence]
        sequences.shift while sequences.size > MAX_TRACKED_WRITERS
      end
      save.update!(data:, byte_size:, writer_sequences: sequences)
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
