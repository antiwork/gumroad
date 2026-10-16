# frozen_string_literal: true

# Erasure overwrites PII columns with update_all/update_columns, which PaperTrail does not version,
# so every earlier snapshot of the row still holds the old values. This blanks those attributes in
# the row's versions and keeps the versions themselves.
class GdprVersionRedactor
  BATCH_SIZE = 1_000

  def self.redact!(item_type:, item_ids:, attributes:)
    new(item_type:, item_ids:, attributes:).redact!
  end

  def initialize(item_type:, item_ids:, attributes:)
    @item_type = item_type
    @item_ids = Array(item_ids)
    @attributes = attributes.map(&:to_s)
  end

  # Returns the number of versions rewritten.
  def redact!
    return 0 if @item_ids.empty?

    rewritten = 0
    @item_ids.each_slice(BATCH_SIZE) do |ids|
      # A locking read sees versions committed after the caller's transaction took its snapshot.
      PaperTrail::Version.where(item_type: @item_type, item_id: ids).lock.find_each do |version|
        object = redacted_object(version.object)
        object_changes = redacted_object_changes(version.object_changes)
        next if object.nil? && object_changes.nil?

        version.update_columns({ object:, object_changes: }.compact)
        rewritten += 1
      end
    end
    rewritten
  end

  private
    def redacted_object(serialized)
      redacted(serialized, nil)
    end

    # Each change is a [before, after] pair; both sides held the PII.
    def redacted_object_changes(serialized)
      redacted(serialized, [nil, nil])
    end

    # nil when nothing changes, so a version whose values are already blank is not rewritten.
    def redacted(serialized, blank)
      attributes = load(serialized)
      return if attributes.nil?

      redacted_attributes = attributes.merge(attributes.slice(*@attributes).transform_values { blank })
      dump(redacted_attributes) unless redacted_attributes == attributes
    end

    def load(serialized)
      return if serialized.blank?

      PaperTrail.serializer.load(serialized)
    end

    def dump(hash)
      PaperTrail.serializer.dump(hash)
    end
end
