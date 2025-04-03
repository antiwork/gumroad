# frozen_string_literal: false

module StripeMetadata
  STRIPE_METADATA_VALUE_MAX_LENGTH = 500

  STRIPE_METADATA_MAX_KEYS_LENGTH = 50

  private_constant :STRIPE_METADATA_VALUE_MAX_LENGTH


  # Public: Builds a hash to be included in Stripe metadata that lists the items passed in, separated by the
  # separator and split over multiple hash keys in the format of key[0], key[1], etc.
  def self.build_metadata_large_list(items, key:, separator: ",", max_value_length: STRIPE_METADATA_VALUE_MAX_LENGTH, max_key_length: STRIPE_METADATA_MAX_KEYS_LENGTH)
    # Stripe metadata has a maximum length of 500 characters per key, so we need to breakup the items across multiple keys.
    items_in_slices = items.each_with_object([]) do |item, slices|
      slice = slices.last
      slice = (slices << "").last if slice.nil? || (slice.length + separator.length + item.length) > max_value_length
      slice << separator if slice.present?
      slice << item
    end
    items_in_slices.each_with_index.map { |slice, index| ["#{key}{#{index}}", slice] }[0..max_key_length].to_h
  end
end
