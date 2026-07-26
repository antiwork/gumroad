# frozen_string_literal: true

# Shared "does this address look like a P.O. Box?" check.
#
# There are two callers, and they need the question answered at two different levels of
# confidence, so this module offers two methods:
#
#   * `match?` is the strict one, used by the payout settings form to REJECT an address up front
#     for countries where our payment partner requires a physical street address. Because it
#     blocks a seller from saving, it only fires on the unmistakable spellings ("PO Box 65",
#     "P.O. Box 65", "P O Box 65"). It has to stay in step with the same check the
#     settings form runs in the browser (`isStreetAddressPOBox` in
#     app/javascript/pages/Settings/Payments/Show.tsx), and widening what we refuse to store is
#     a product decision, not a detail of this module.
#
#   * `possible_match?` is the lenient one, used only to choose which explanation a seller reads
#     after their verification document has ALREADY been rejected for an address mismatch. It
#     also catches the bare box-and-number form ("Box 65, RR 2"), which is how rural sellers with
#     no civic street address normally write a post office box. Nothing is blocked on the back of
#     this answer, so a false positive costs a seller nothing worse than being pointed at support.
#
# The reason the lenient answer matters: the account address can't be a P.O. Box, but every
# document the seller owns shows their registered P.O. Box, so no document can ever match the
# account and re-uploading is guaranteed to fail. Sellers stuck in that deadlock need to be told
# so, and the ones most likely to be in it are exactly the rural sellers who write "Box 65, RR 2"
# rather than "PO Box 65". See UserComplianceInfoRequest for the full description.
module PoBoxAddress
  # Looked for in the address once every character that isn't a letter, digit, or underscore has
  # been removed, so it covers "PO Box 65", "P.O. Box 65" and "P O BOX 65".
  EXPLICIT = "pobox"

  # Matched against the address as written, so the word boundary is still meaningful. Catches
  # "Box 65", "Box #65", "Box65" and "Post Office Box 65" without catching "Boxwood Lane 4" (the
  # digit has to follow "box" itself) or "12 Mailbox Road" ("box" there is not the start of a word).
  BARE_BOX_AND_NUMBER = /\bbox\s*[#.]?\s*\d/i

  # A deliberately loose SQL `LIKE` pattern for callers that need to narrow a table down before
  # asking `possible_match?` about individual addresses. It matches any address containing the
  # letters b, o and x in that order, which is a guaranteed superset of everything either method
  # above can match: the strict one only fires on spellings that reduce to "pobox" once
  # punctuation is dropped (so the three letters are present and in order even in "P.O.B.O.X"),
  # and the lenient one needs the literal word "box".
  #
  # It also matches plenty of addresses that are no kind of post office box ("Boxwood Lane") —
  # that is fine and intended. The point is to hand Ruby a couple of candidate rows instead of a
  # seller's entire compliance history, not to make the decision. `po_box_address_spec.rb` guards
  # the superset property, so a spelling added to either method later cannot silently start being
  # filtered out here.
  POSSIBLE_MATCH_SQL_HINT = "%b%o%x%"

  # Only the spellings that unambiguously say "post office box". Safe to block a seller on.
  def self.match?(address)
    return false if address.blank?

    normalize(address).include?(EXPLICIT)
  end

  # The spellings above, plus the bare box-and-number form. Use for messaging, never for blocking.
  def self.possible_match?(address)
    return false if address.blank?

    match?(address) || address.to_s.match?(BARE_BOX_AND_NUMBER)
  end

  def self.normalize(address)
    address.to_s.gsub(/[^\w]/, "").downcase
  end
  private_class_method :normalize
end
