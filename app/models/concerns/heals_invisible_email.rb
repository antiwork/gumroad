# frozen_string_literal: true

# Removes invisible characters from an email-shaped column before validation, so a row that was
# stored before we started refusing them can still be saved.
#
# Why this exists: the email validations on these columns run on EVERY save, not only when the
# column changes. Once we refuse invisible characters, a row that already carries one becomes
# unsaveable — publishing a product, changing an unrelated setting, or any background job that
# saves the record would fail over a field the current operation never touched. Healing the value
# on the way through means the row repairs itself on its next save.
#
# This is the opposite choice from User#email, which is left alone on purpose: that address is the
# person's identity, so we want them TOLD it is wrong rather than have it changed underneath them.
# The columns healed here (a support address, a PayPal payout address, an affiliate applicant's
# address) are ones where the alternative is a record nobody can save at all.
#
# Note this deliberately does NOT touch ordinary ASCII whitespace or turn a blank value into nil.
# Those are visible to the person typing, existing validations already have opinions about them,
# and changing them here would alter behaviour well beyond invisible characters.
module HealsInvisibleEmail
  extend ActiveSupport::Concern

  class_methods do
    def heals_invisible_email(*fields)
      before_validation do
        fields.each do |field|
          value = read_attribute(field)
          next if value.nil?

          healed = InvisibleCharacters.remove_from_email(value)
          write_attribute(field, healed) unless healed == value
        end
      end
    end
  end
end
