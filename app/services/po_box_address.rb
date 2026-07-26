# frozen_string_literal: true

# Shared "does this address look like a P.O. Box?" check.
#
# Sellers write P.O. Boxes many different ways ("PO Box 65", "P.O. Box 65", "Box 65, RR 2"),
# so we strip every character that isn't a letter, digit, or underscore and look for the
# "pobox" sequence in what's left.
#
# Two places need the same answer:
#   * the payout settings form, which blocks a P.O. Box up front for countries where our
#     payment partner requires a physical street address, and
#   * the verification-error copy, which needs to know whether a seller is caught in the
#     P.O. Box deadlock — the account address can't be a P.O. Box, but every document the
#     seller owns shows their registered P.O. Box, so no document can ever match the
#     account and re-uploading is guaranteed to fail.
module PoBoxAddress
  def self.match?(address)
    return false if address.blank?

    address.to_s.gsub(/[^\w]/, "").downcase.include?("pobox")
  end
end
