# frozen_string_literal: true

# Strips invisible characters off recipient addresses just before delivery.
#
# Some accounts were created before we started refusing addresses that carry a character the
# person typing cannot see (see InvisibleCharacters), so their stored address still holds one.
# Every message to such an address is rejected by the mail provider, and the person has no way to
# tell: the address they typed is a real working mailbox and the character renders as nothing.
# Their symptom is silence.
#
# Cleaning the recipient here, at the last point before the message leaves, means those accounts
# start receiving mail again without waiting for their stored address to be corrected. It also
# keeps the mailers' own `EmailFormatValidator.valid?` guards from turning into a silent
# no-delivery: those guards refuse an address with an invisible character now that the validator
# rejects one, and refusing to send is the opposite of what this fix is for.
#
# This only rewrites the envelope for this delivery. It deliberately does NOT touch the stored
# record — repairing the row is a separate, auditable backfill, and a delivery-time hook is the
# wrong place to be writing to the database.
#
# The one case where cleaning is NOT safe is when the cleaned address is the stored address of a
# DIFFERENT account. Two accounts can hold the two variants of the same-looking address: one
# signed up before we started refusing hidden characters, the other after. Rewriting the
# recipient there would take a message addressed to the first account — a password reset link, a
# login code, a receipt with download links — and deliver it to the second account's mailbox,
# whose owner could then take over the first account. So when the database shows two separate
# accounts behind the two variants, the address is left exactly as it was addressed. That
# delivery still bounces at the mail provider, which is what happened before this fix existed;
# silence for one account is recoverable, handing that account to a stranger is not.
class InvisibleCharacterRecipientSanitizer
  def self.delivering_email(message)
    %i[to cc bcc].each do |field|
      addresses = message.send(field)
      next if addresses.blank?

      addresses = Array(addresses)
      cleaned = addresses.map { sanitized_recipient(_1) }
      message.send("#{field}=", cleaned) if cleaned != addresses
    end
  end

  # The cleaned form of one recipient, or the recipient untouched when cleaning it would point the
  # message at somebody else's mailbox.
  def self.sanitized_recipient(address)
    # Almost every delivery takes this line and never reaches the database. The lookup below only
    # runs for an address that actually carries an invisible character, which is rare.
    return address unless InvisibleCharacters.present_in?(address.to_s)

    normalized = InvisibleCharacters.normalize_email(address.to_s)
    return address if normalized == address || normalized.blank?
    return address if owned_by_a_different_account?(address.to_s, normalized)

    normalized
  end
  private_class_method :sanitized_recipient

  # True when one account stores the address exactly as it was addressed here and a DIFFERENT
  # account stores the cleaned form.
  def self.owned_by_a_different_account?(address, normalized)
    # One query returns all rows the database considers equal to either form: the email column
    # collates as utf8mb4_unicode_ci, which treats the format characters here as ignorable, so
    # `WHERE email = '<RLM>buyer@example.com'` can also match `buyer@example.com`,
    # `Buyer@example.com`, and another format-character variant. The database therefore cannot
    # tell those variants apart, and the rows have to be compared here in Ruby, byte for byte.
    #
    # Both variants are named in the query as literals, so each is found by matching itself
    # exactly, whether or not the collation considers the two equal. A Unicode space is NOT
    # collation-ignorable the way a format character is (`buyer\u00A0@example.com` does not compare
    # equal to `buyer@example.com` in MySQL), but that does not matter here: the dirty form is the
    # first literal and the cleaned form is the second, so a Unicode-space pair is detected just as
    # a format-character pair is. Collation only widens what comes back; it is never what makes a
    # variant visible.
    #
    # The remaining hole needs BOTH accounts to store a dirty address, from the two different
    # classes: this account stored with a format character (`<RLM>buyer@example.com`, cleaning to
    # `buyer@example.com`) while the other account stored the SAME mailbox with a Unicode space
    # (`buyer\u00A0@example.com`). Neither literal in the query matches that row and the collation
    # does not reach it either, so cleaning goes ahead and the message lands in the other person's
    # mailbox. Closing it needs a stored normalized-email column to look up, because the other
    # row's dirty form cannot be reconstructed from this one — we know the mailbox the cleaned
    # address points at, not where somebody else's invisible character sat inside it.
    rows = User.where(email: [address, normalized]).select(:id, :email).to_a
    rows.any? { _1.email == address } && rows.any? { _1.email != address }
  end
  private_class_method :owned_by_a_different_account?
end
