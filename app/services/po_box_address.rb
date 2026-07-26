# frozen_string_literal: true

# Shared "does this address look like a P.O. Box?" check.
#
# Two places need the same answer:
#   * the payout settings form, which blocks a P.O. Box up front for countries where our
#     payment partner requires a physical street address, and
#   * the verification-error copy, which needs to know whether a seller is caught in the
#     P.O. Box deadlock — the account address can't be a P.O. Box, but every document the
#     seller owns shows their registered P.O. Box, so no document can ever match the
#     account and re-uploading is guaranteed to fail.
#
# Sellers write P.O. Boxes many different ways, and the postal services publish more than one
# accepted format, so we recognise two shapes:
#
#   * The spelled-out forms — "PO Box 65", "P.O. Box 65", "Post Office Box 65", and the spaced
#     out "P O B O X 65". We first strip every character that isn't a letter or digit, which
#     collapses all the punctuation and spacing variants onto the same string, then look for
#     the collapsed keyword in what's left.
#   * The short form used in rural addresses, where the box number is effectively the whole
#     address line — "Box 65", "Box 65, RR 2", "Box #65", "Box no. 65". This one is matched
#     against the ORIGINAL text, not the stripped version, because it needs the word boundary
#     in front of "box" to stay intact: without it, "Sandbox 5" and "Mailbox 12" would match.
#
# An address that merely contains "box" without a following number ("Boxwood Lane") is a normal
# street address and is deliberately left alone.
module PoBoxAddress
  # Matched against the address with all non-alphanumeric characters removed, so every spacing
  # and punctuation variant of these words collapses onto one of these strings.
  STRIPPED_KEYWORDS = %w[pobox postofficebox].freeze

  # "Box" as its own word followed by a box number, optionally via "#" or "no.".
  # Matched against the original text so the leading word boundary is preserved.
  SHORT_FORM = /\bbox\s*(?:#|no\.?\s*)?\d/i

  def self.match?(address)
    return false if address.blank?

    text = address.to_s
    stripped = text.gsub(/[^[:alnum:]]/, "").downcase

    return true if STRIPPED_KEYWORDS.any? { |keyword| stripped.include?(keyword) }

    text.match?(SHORT_FORM)
  end
end
