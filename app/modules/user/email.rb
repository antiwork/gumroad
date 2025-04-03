# frozen_string_literal: true

module User::Email
  # To reduce invalid email address errors, we enforcing the same email regex as the front end
  EMAIL_REGEX = /\A(?=.{3,255}$)(                                         # between 3 and 255 characters
                ([^@\s()\[\],.<>;:\\"]+(\.[^@\s()\[\],.<>;:\\"]+)*)       # cannot start with or have consecutive .
                |                                                         # or
                (".+"))                                                   # local part can be in quotes
                @
                ((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\])     # IP address
                |                                                         # or
                (([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,})                         # domain can only alphabets and . -
                )\z/x

  RESERVED_EMAIL_DOMAINS = %w[gumroad.com gumroad.org gumroad.dev]

  def email_domain_reserved?(email)
    Mail::Address.new(email).domain.try(:in?, RESERVED_EMAIL_DOMAINS)
  end
end
