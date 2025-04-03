# frozen_string_literal: true

# Describe where funds collected by creating a charge at a charge processor
# are held until they are paid out to the creator.
module HolderOfFunds
  GUMROAD = "gumroad"
  STRIPE = "stripe"
  CREATOR = "creator"
end
