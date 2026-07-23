# frozen_string_literal: true

# Some shared spec/support helpers emit debug output via
# `RSpec.current_example.full_description` / `.location`. The clearest example is
# StripeMerchantAccountHelper#ensure_charges_enabled, which prints those while
# fast-forwarding through a recorded Stripe cassette (the loop body runs on every
# replay, not just when recording).
#
# Under Minitest there is no running RSpec example, so `RSpec.current_example`
# returns nil and those `puts` crash with NoMethodError. RSpec is loaded in the
# test environment (Bundler.require pulls in rspec-rails), so provide a harmless
# stand-in that responds to the two methods the helpers call — letting
# Stripe-account builders (create_merchant_account_stripe, etc.) replay cassettes
# identically to the RSpec suite.
module RSpec; end unless defined?(RSpec)

RSpec.singleton_class.define_method(:current_example) do
  @minitest_current_example ||=
    Struct.new(:full_description, :location).new("minitest (no RSpec example)", "test/")
end
