# frozen_string_literal: true

class EmailFormatValidator < ActiveModel::EachValidator
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

  # Shown instead of the generic "is invalid" when the only thing wrong with the address is a
  # character the person cannot see. Without this they get told their address is invalid while
  # looking straight at an address that is, as far as they can tell, spelled perfectly.
  INVISIBLE_CHARACTER_MESSAGE = "contains a hidden character. Please delete it and type it again " \
                                "instead of pasting."

  class << self
    def valid?(email)
      return false if email.blank?
      # An address carrying a character the person cannot see is not a valid address, even
      # though the regex below happily matches it: the local part of an address may contain
      # almost anything, so a leading U+200F RIGHT-TO-LEFT MARK reads as just another ordinary
      # character. We refuse it rather than repairing it silently, because an address is an
      # identity — quietly storing something other than what was typed is how an account ends
      # up receiving no mail at all with nobody able to work out why.
      return false if InvisibleCharacters.present_in?(email)
      email.to_s.match?(EMAIL_REGEX)
    end

    # True when the address would be valid if it did not carry invisible characters. Used to
    # pick the error message, so we can explain the actual problem.
    #
    # This removes the invisible characters WITHOUT trimming ordinary whitespace on purpose: an
    # address that also has a visible stray space is not a hidden-character problem, and telling
    # the person about a hidden character would send them looking for the wrong thing.
    def invisible_characters_only?(email)
      return false if email.blank?
      return false unless InvisibleCharacters.present_in?(email)
      InvisibleCharacters.remove_from_email(email).match?(EMAIL_REGEX)
    end

    # Whether we should attempt to DELIVER to this address, which is a different question from
    # whether we would accept it as input today.
    #
    # Addresses stored before we started refusing invisible characters still carry them, and the
    # delivery-time sanitizer cleans the recipient on the way out, so such an address is
    # genuinely deliverable. Mailers must use this rather than valid?: guarding delivery on
    # valid? would make us silently stop mailing exactly the accounts that already receive
    # nothing, which is the problem we are fixing rather than a safety check.
    def deliverable?(email)
      valid?(InvisibleCharacters.normalize_email(email))
    end
  end

  def validate_each(record, attribute, value)
    return if value.nil? && options[:allow_nil]
    return if value.blank? && options[:allow_blank]
    return if self.class.valid?(value)

    if self.class.invisible_characters_only?(value)
      record.errors.add(attribute, INVISIBLE_CHARACTER_MESSAGE)
    else
      record.errors.add(attribute, options[:message] || :invalid)
    end
  end
end
