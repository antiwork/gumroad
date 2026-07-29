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
  # account stores the same mailbox — either the cleaned form, or the cleaned form with some other
  # invisible character sitting inside it.
  def self.owned_by_a_different_account?(address, normalized)
    # The addresses to ask the database about are the cleaned form plus every single-invisible-
    # character variant of it, because the row we are protecting against may hold ANY of them.
    #
    # Naming only the addressed value and its cleaned form is not enough, and this is the part
    # that is easy to get wrong: the email column collates as utf8mb4_unicode_ci, which treats
    # SOME of these characters as ignorable but not others. Measured on MySQL 8.0:
    # '<RLM>buyer@example.com' = 'buyer@example.com' is TRUE, while
    # 'buyer<NBSP>@example.com' = 'buyer@example.com' is FALSE, and a soft hyphen behaves like the
    # space rather than like the mark. So a two-literal lookup silently reaches an account holding
    # one class of invisible character and silently misses an account holding the other — and
    # missing it is what rewrites this message into that person's mailbox.
    #
    # Enumerating the variants removes the collation from the reasoning altogether: every form we
    # care about is named as its own literal and found by matching itself. The query stays a range
    # scan on index_users_on_email (measured against production: 902 literals for a 40-character
    # address, ~3 ms warm), and it only runs for an address that actually carries an invisible
    # character, which is rare.
    candidates = InvisibleCharacters.email_variants(normalized)

    # email_variants declines addresses longer than it will expand. Nothing has been ruled out in
    # that case, so fail closed and leave the recipient as addressed: the message bounces, which
    # is what happened before this interceptor existed, rather than possibly landing in somebody
    # else's mailbox.
    return true if candidates.nil?

    # Deleted accounts count. Delivery goes to a real external mailbox, not to a Gumroad account,
    # so a closed account that once owned this address is still evidence that somebody else may
    # read that mailbox.
    rows = User.where(email: candidates + [address]).select(:id, :email).to_a

    # Compared in Ruby, byte for byte, because the collation cannot tell the variants apart and
    # would otherwise let a row that merely compares equal stand in for the addressed account.
    return false unless rows.any? { _1.email == address }

    rows.any? { _1.email != address }
  end
  private_class_method :owned_by_a_different_account?
end
