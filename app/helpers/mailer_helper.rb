# frozen_string_literal: true

module MailerHelper
  # This regex matches all non-ASCII characters from the Latin script
  EXTENDED_LATIN_REGEX = /[\p{InLatin-1_Supplement}|\p{InLatin_Extended-A}|\p{InLatin_Extended-B}]/
  # This regex matches if there is a non-ASCII character from the Latin script AND a symbol
  EXTENDED_LATIN_AND_SYMBOL_REGEX = /(#{EXTENDED_LATIN_REGEX}.*[[:punct:]])|([[:punct:]].*#{EXTENDED_LATIN_REGEX})/m
  private_constant :EXTENDED_LATIN_REGEX, :EXTENDED_LATIN_AND_SYMBOL_REGEX
  def header_section(heading, subheading = nil)
    render("layouts/mailers/header_section", heading:, subheading:)
  end

  def variant_names_displayable(names)
    Class.new.extend(ProductsHelper).variant_names_displayable(names)
  end

  def creators_from_email_address(username = nil)
    "#{username.presence || "creators"}@#{CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN}"
  end

  def from_email_address_name(name)
    # SendGrid bounces emails where the creator's name contains
    # at least one letter with accents and at least one symbol.
    # In order to go around this issue, we fallback to using "Gumroad" as the sender name when this scenario occurs.
    if name.present? && !name.match?(EXTENDED_LATIN_AND_SYMBOL_REGEX)
      # Some mails are sent in batches via Resend, and Resend doesn't accept special characters like colons in from fields
      # So we remove those characters from the sender name if any
      name.delete("\n").gsub(User::INVALID_NAME_FOR_EMAIL_DELIVERY_REGEX, "").strip
    else
      "Gumroad"
    end
  end
end
