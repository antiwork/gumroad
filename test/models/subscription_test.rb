# frozen_string_literal: true

require "test_helper"

# Ported from spec/models/subscription_spec.rb (#2 in the #5801 factory-time
# ranking: 1:02 setup, 79% factory). Subscription is exercised through model
# logic — billing lifecycle, charges, cancellation, resubscription — so objects
# are built with the shared ModelFactories helpers. HTTP-touching paths replay
# the existing RSpec cassettes via the VCR bridge (#5938).
class SubscriptionTest < ActiveSupport::TestCase
  # Port in progress — tests land incrementally on this branch.
end
