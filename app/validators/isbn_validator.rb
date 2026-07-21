# frozen_string_literal: true

class IsbnValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    return if value.nil? && options[:allow_nil]
    return if value.blank? && options[:allow_blank]

    isbn_digits = value.delete("-")

    valid =
      if isbn_digits.length == 10
        validate_with_isbn10(isbn_digits)
      elsif isbn_digits.length == 13
        validate_with_isbn13(isbn_digits)
      else
        false
      end

    record.errors.add(attribute, options[:message] || "is not a valid ISBN-10 or ISBN-13") unless valid
  end

  private
    def validate_with_isbn10(isbn)
      # Reject anything that isn't 9 digits followed by a digit or "X"/"x"
      # check character before running the checksum. Without this guard,
      # String#to_i coerces letters/punctuation to 0, so an all-letter string
      # sums to 0 and 0 % 11 == 0 makes garbage like "helloworld" pass.
      return false unless isbn.match?(/\A\d{9}[\dXx]\z/)

      check_digit = isbn[-1].casecmp?("X") ? 10 : isbn[-1].to_i
      sum = isbn[0...-1].chars.each_with_index.sum { |d, i| (i + 1) * d.to_i }
      sum % 11 == check_digit
    end

    def validate_with_isbn13(isbn)
      # ISBN-13 is strictly 13 digits. Same reason as above: without this
      # guard, non-digit characters coerce to 0 and the all-zero sum is a
      # multiple of 10, so strings like "AAAAAAAAAAAAA" would pass.
      return false unless isbn.match?(/\A\d{13}\z/)

      digits = isbn.chars.map(&:to_i)
      sum = digits.each_with_index.sum { |d, i| i.even? ? d : 3 * d }
      sum.multiple_of?(10)
    end
end
