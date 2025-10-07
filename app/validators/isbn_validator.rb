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
      check_digit = isbn[-1] == "X" ? 10 : isbn[-1].to_i
      sum = isbn[0...-1].chars.each_with_index.sum { |d, i| (i + 1) * d.to_i }
      sum % 11 == check_digit
    end

    def validate_with_isbn13(isbn)
      digits = isbn.chars.map(&:to_i)
      sum = digits.each_with_index.sum { |d, i| i.even? ? d : 3 * d }  # 100
      sum.multiple_of?(10)
    end
end
