# frozen_string_literal: true

TAG = "qa6683r16b"
RUN = SecureRandom.hex(3)
def mark(k, v) = puts("MARK #{k}=#{v}")
mark "RUN", RUN
M = StripeGuardianManager

CALLS = []
Stripe::Account.singleton_class.define_method(:delete_person) do |a, p|
  CALLS << [a, p]
  raise Stripe::InvalidRequestError.new("No such person: #{p}", nil, code: "resource_missing")
end

# ARM D's pre-fix cell, PRODUCED rather than asserted: with the old `stripe_account_ids.empty?`
# gate, no unreachable claim was made, so the erasure went on to delete the recorded Person
# against the account that DID resolve. Stripe answers "no such person" there, because the Person
# sits on the account we cannot resolve -- and delete_person_by_id reports that as success.
hidden = "person_#{TAG}_#{RUN}_on_unresolvable"
good   = "acct_#{TAG}_#{RUN}_good"
mark "D_prefix_delete_against_good_account", M.delete_person_by_id(hidden, good)
mark "D_prefix_delete_called_with", CALLS.inspect
raise "ABORT the pre-fix delete did not report success" unless M.delete_person_by_id(hidden, good) == true

# ARM F's pre-fix cell, PRODUCED: the old guard in existing_person was
# `raise unless e.message.to_s.include?("No such person")` -- evaluated on the very error object
# arm F forced, whose code is account_invalid, not resource_missing.
err = Stripe::InvalidRequestError.new("Permission denied. No such person: person_x", nil, code: "account_invalid")
mark "F_error_code", err.code.inspect
mark "F_prefix_guard_swallows", err.message.to_s.include?("No such person")
mark "F_branch_guard_reraises", !(err.code == "resource_missing")
raise "ABORT the pre-fix guard did not swallow it" unless err.message.to_s.include?("No such person")
raise "ABORT the branch guard does not re-raise it" if err.code == "resource_missing"

# The same pair for delete_person_by_id, which the existing_person comment cites as the precedent.
mark "F_delete_by_id_code_gate_present",
     File.read(Rails.root.join("app/business/payments/merchant_registration/implementations/stripe/stripe_guardian_manager.rb"))[
       /def self\.delete_person_by_id.*?^  end$/m].to_s.include?('raise unless e.code == "resource_missing"')

mark "RUN_OK", true
