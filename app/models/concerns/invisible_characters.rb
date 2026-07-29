# frozen_string_literal: true

# The set of characters that a person cannot see but that we still store as real bytes,
# plus the helpers for removing them.
#
# These arrive from copy/paste (a bidirectional mark travels along with text copied out of a
# right-to-left document), from right-to-left keyboard layouts, and from PDFs that use a soft
# hyphen as a line-break hint. Because they render as nothing, a value containing one looks
# byte-for-byte correct both to the person typing it and to us in the database, while every
# downstream system that matches on that value quietly fails.
#
# The email address is the case that hurts most. An address with a leading U+200F is a
# perfectly well-formed address as far as our validation is concerned, so we accept it at
# signup and at checkout, and then the mail provider rejects every message we send to it. The
# person sees no error anywhere: the address they typed is a real, working mailbox. They just
# never hear from us again, and a support search for the address they believe they typed cannot
# find their row, because the invisible character is the first byte.
#
# This module is the single source of truth for that character set, so the strip helper
# (StrippedFields), the validation that rejects the address outright (EmailFormatValidator),
# and the models that normalize an email on their own all agree on exactly which characters
# count as invisible.
module InvisibleCharacters
  extend self

  # Format characters: invisible AND carry no width, so removing them is always safe.
  #
  # Deliberately EXCLUDED, even though they sit inside the same Unicode block:
  #   * U+200C ZERO WIDTH NON-JOINER — carries meaning in Persian, Arabic and several Indic
  #     scripts (it is what keeps "می‌روم" two words). Deleting it corrupts real names.
  #   * U+200D ZERO WIDTH JOINER — the glue inside multi-codepoint emoji (family and flag
  #     sequences) and inside Indic conjuncts. Sellers put emoji in display names, so deleting
  #     it would visibly mangle them.
  # Both are semantic content rather than formatting, which is why this is a hand-picked list
  # rather than the whole U+200B–U+200F range.
  FORMAT_CHARS = /[\u00AD\u200B\u200E\u200F\u2060\uFEFF]/

  # Unicode space separators. Ruby's String#strip only knows ASCII whitespace, so these survive
  # it and then behave like content. We fold them to a plain space rather than delete them so
  # the word boundary the person intended is preserved — "Ada Lovelace" typed with a no-break
  # space stays two words instead of becoming "AdaLovelace".
  UNICODE_SPACES = /[\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]/

  # Anything the two sets above cover. Used to ask "does this value contain an invisible
  # character at all", which is how we reject an email address instead of silently repairing it.
  ANY = Regexp.union(FORMAT_CHARS, UNICODE_SPACES)

  # True when the value contains a character the person who typed it cannot see.
  def present_in?(value)
    value.to_s.match?(ANY)
  end

  # Removes the format characters and folds Unicode spaces down to a plain space. Callers are
  # expected to follow this with their own String#strip, since folding can leave a leading or
  # trailing ASCII space behind.
  def remove(value)
    value.to_s.gsub(FORMAT_CHARS, "").gsub(UNICODE_SPACES, " ")
  end

  # Removes only the characters a person cannot see from an email address, leaving ordinary
  # ASCII whitespace exactly where it was.
  #
  # Unlike a name, an address has no word boundaries, so a Unicode space is deleted rather than
  # folded to a plain space — someone whose address arrived with a no-break space in it meant no
  # space at all.
  #
  # Ordinary spaces and tabs are left alone on purpose. They are visible in the input field, so
  # an address with a stray trailing space is a mistake the person can see and existing
  # validation already refuses it; repairing that here would quietly widen what we accept
  # everywhere, which is not what this change is for.
  #
  # One deliberate imprecision: RFC 5321 permits a quoted local part that really does contain a
  # Unicode space (`"a\u00A0b"@example.com`), and this deletes it. That shape is vanishingly
  # rare and most mail providers reject it outright. If a real address is ever reported broken
  # by this, the fix is to skip normalization when the local part is quoted.
  def remove_from_email(value)
    return value if value.nil?
    value.to_s.gsub(FORMAT_CHARS, "").gsub(UNICODE_SPACES, "")
  end

  # remove_from_email plus a trim of the surrounding ASCII whitespace, for the paths that accept
  # an address a person pasted (a settings text area, a password-reset lookup) where a leading
  # or trailing space is noise rather than a mistake worth reporting.
  def normalize_email(value)
    return value if value.nil?
    remove_from_email(value).strip
  end

  # Every character this module treats as invisible, as single-character strings. ALL is the
  # ordered list behind email_variants below; ANY is the same set as a regexp.
  ALL = ([
    "\u00AD", "\u200B", "\u200E", "\u200F", "\u2060", "\uFEFF"
  ] + ["\u00A0", "\u1680", "\u202F", "\u205F", "\u3000"] + (0x2000..0x200A).map { [_1].pack("U") }).uniq.freeze

  # The longest cleaned address email_variants will expand. An address needs one literal per
  # (position x invisible character), so the work grows with its length; past this length we stop
  # expanding rather than build an unbounded query. Real addresses are far shorter than this —
  # the longest cleaned address among the affected production rows is 33 characters.
  MAX_VARIANT_LENGTH = 100

  # Every address that differs from `cleaned` by exactly ONE invisible character, plus `cleaned`
  # itself.
  #
  # This exists because MySQL cannot find those rows for us. A lookup can only name literals it
  # can construct, and knowing the mailbox an address points at does not tell us where somebody
  # else's invisible character sat inside it, so the variants have to be enumerated. Collation
  # does not cover the difference either: only SOME of these characters are ignorable under
  # utf8mb4_unicode_ci (measured — U+200B, U+200E, U+200F, U+2060 and U+FEFF are; U+00AD and
  # every Unicode space are NOT), so a plain literal reaches some variants and misses others.
  #
  # Returns nil when the address is too long to expand or is blank, so a caller can tell "no
  # variant owns this" apart from "I did not look".
  def email_variants(cleaned)
    cleaned = cleaned.to_s
    return nil if cleaned.blank? || cleaned.length > MAX_VARIANT_LENGTH

    variants = [cleaned]
    (0..cleaned.length).each do |position|
      ALL.each { variants << cleaned.dup.insert(position, _1) }
    end
    variants.uniq
  end
end
