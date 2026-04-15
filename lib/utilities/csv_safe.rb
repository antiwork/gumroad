# frozen_string_literal: true

require "csv"

# Custom CSV sanitization to prevent formula injection
# Based on csv-safe gem but modified to preserve numeric strings with + or -
# Original: https://github.com/zvory/csv-safe/blob/master/lib/csv-safe.rb
class CsvSafe < CSV
  FORMULA_PREFIXES = ["=", "@", "|", "%", "\r", "\t"].freeze
  NUMERIC_PATTERN = /\A\d+\.?\d*\z/

  def <<(row)
    super(sanitize_row(row))
  end
  alias_method :add_row, :<<
  alias_method :puts, :<<

  private
    def sanitize_row(row)
      case row
      when CSV::Row then row.fields.map { |field| sanitize_field(field) }
      when Hash then headers.map { |header| sanitize_field(row[header]) }
      else row.map { |field| sanitize_field(field) }
      end
    end

    def sanitize_field(field)
      return field if field.nil? || field.is_a?(Numeric)

      str = field.to_s
      needs_sanitization?(str) ? "'#{str}" : field
    end

    def needs_sanitization?(str)
      return false if str.empty?

      first_char = str[0]

      if first_char == "+" || first_char == "-"
        rest = str[1..]
        return false if rest&.match?(NUMERIC_PATTERN)
      end

      FORMULA_PREFIXES.include?(first_char) || first_char == "+" || first_char == "-"
    end
end
