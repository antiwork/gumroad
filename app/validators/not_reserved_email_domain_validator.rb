# frozen_string_literal: true

class NotReservedEmailDomainValidator < ActiveModel::EachValidator
  RESERVED_EMAIL_DOMAINS = %w[gumroad.com gumroad.org gumroad.dev].freeze

  class << self
    def domain_reserved?(email)
      return false if email.blank?

      domain = Mail::Address.new(email).domain
      domain&.downcase&.in?(RESERVED_EMAIL_DOMAINS)
    rescue Mail::Field::ParseError
      false
    end
  end

  def validate_each(record, attribute, value)
    if self.class.domain_reserved?(value)
      record.errors.add(attribute, options[:message] || "is reserved")
    end
  end
end
