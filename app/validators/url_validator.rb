# frozen_string_literal: true

class UrlValidator < ActiveModel::EachValidator
  URL_REGEX = /\A#{URI::DEFAULT_PARSER.make_regexp(%w[http https])}\z/

  def validate_each(record, attribute, value)
    return if value.blank?

    if !valid_url_format?(value)
      record.errors.add(attribute, options[:message] || :invalid_url)
    end
  end

  private

  def valid_url_format?(url)
    url.match?(URL_REGEX) && url.length <= 2048
  end
end
