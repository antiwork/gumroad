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

  # One representative per COLLATION EQUIVALENCE CLASS of the characters above, for building
  # lookup literals. Under the email column's utf8mb4_unicode_ci collation these characters are
  # not all distinct, which means a lookup does not need one literal per character — it needs one
  # per class. Measured on production MySQL 8.0.42 against `users.email`:
  #
  #   * The five marks — U+200B, U+200E, U+200F, U+2060, U+FEFF — have NO collation weight at all.
  #     `'<ZWSP>buyer@example.com' = 'buyer@example.com'` is TRUE, and it stays true for any
  #     number of them in any position, so the cleaned address by itself already matches every row
  #     that differs only by marks. They need no representative.
  #   * Every Unicode space EXCEPT U+1680 collates equal to an ASCII space, so a single
  #     space literal reaches all fifteen of them.
  #   * U+1680 OGHAM SPACE MARK and U+00AD SOFT HYPHEN each collate as themselves. The soft hyphen
  #     is the trap here: it sits in the same Unicode block as the marks and reads like one, but it
  #     is NOT ignorable, so it has to be named.
  #
  # Three representatives instead of twenty-two, and wider rather than narrower: unlike a
  # per-character list this reaches an address holding any number of marks.
  VARIANT_CLASS_REPRESENTATIVES = [" ", "\u1680", "\u00AD"].freeze

  # The longest cleaned address email_variants will expand, per number of inserted characters.
  # Expanding costs one literal per (combination of positions x combination of classes), so the
  # work grows with the address length and steeply with the count; past these lengths we stop
  # expanding and let the caller fail closed rather than build an unbounded query.
  #
  # Real addresses are far shorter: the longest cleaned address among the affected production rows
  # is 33 characters, and 33 characters costs 103 literals at one inserted character and 5,152 at
  # two (measured against production: index range scan on index_users_on_email, 6 ms warm).
  MAX_VARIANT_LENGTH = 100
  MAX_PAIR_VARIANT_LENGTH = 40

  # The most invisible characters email_variants will assume the OTHER row might hold. Two, because
  # the worst case in production today is two (a single address holding two no-break spaces) and
  # because this PR's entry-point validation refuses a dirty address, so a row holding three would
  # have to be written straight to the column by a data migration or an admin correction.
  # `email_variants_complete?` reports whether this bound actually covered a given address, so a
  # caller can fail closed instead of assuming.
  MAX_VARIANT_CHARACTERS = 2

  # Every address that collates equal to a value differing from `cleaned` by up to
  # MAX_VARIANT_CHARACTERS invisible characters, plus `cleaned` itself.
  #
  # This exists because MySQL cannot find those rows for us. A lookup can only name literals it can
  # construct, and knowing which mailbox an address points at does not tell us where somebody
  # else's invisible characters sat inside it, so the variants have to be enumerated. Collation
  # covers part of the gap but not all of it — see VARIANT_CLASS_REPRESENTATIVES for what is
  # measured to be equal to what.
  #
  # Returns nil when the address is blank or too long to expand, so a caller can tell "no variant
  # owns this" apart from "I did not look".
  def email_variants(cleaned)
    cleaned = cleaned.to_s
    return nil if cleaned.blank? || cleaned.length > MAX_VARIANT_LENGTH

    # The cleaned address alone already covers every row that differs only by ignorable marks.
    variants = [cleaned]
    positions = (0..cleaned.length).to_a

    (1..variant_characters_for(cleaned)).each do |count|
      positions.combination(count) do |combination|
        VARIANT_CLASS_REPRESENTATIVES.repeated_permutation(count) do |characters|
          variant = cleaned.dup
          # Insert from the rightmost position first so earlier insertions do not shift the
          # positions still to be used.
          combination.each_with_index.reverse_each { |position, index| variant.insert(position, characters[index]) }
          variants << variant
        end
      end
    end

    variants.uniq
  end

  # True when email_variants covered the full MAX_VARIANT_CHARACTERS for this address. False when
  # the address was long enough that expansion had to be cut short, which is a caller's signal to
  # fail closed rather than treat "no variant found" as "nobody else owns this mailbox".
  def email_variants_complete?(cleaned)
    cleaned = cleaned.to_s
    return false if cleaned.blank? || cleaned.length > MAX_VARIANT_LENGTH

    variant_characters_for(cleaned) >= MAX_VARIANT_CHARACTERS
  end

  private
    def variant_characters_for(cleaned)
      cleaned.length > MAX_PAIR_VARIANT_LENGTH ? 1 : MAX_VARIANT_CHARACTERS
    end
end
