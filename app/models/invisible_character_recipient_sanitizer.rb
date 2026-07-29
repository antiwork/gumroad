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
class InvisibleCharacterRecipientSanitizer
  def self.delivering_email(message)
    %i[to cc bcc].each do |field|
      addresses = message.send(field)
      next if addresses.blank?

      cleaned = Array(addresses).map { InvisibleCharacters.normalize_email(_1) }
      message.send("#{field}=", cleaned) if cleaned != Array(addresses)
    end
  end
end
