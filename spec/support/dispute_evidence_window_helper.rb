# frozen_string_literal: true

# Specs that build windows from Time.current and expect the plain 72 hours would otherwise pass or
# fail depending on the weekday they run. The weekend rule has its own examples in
# spec/models/dispute_evidence_spec.rb.
RSpec.shared_context "without the weekend window extension" do
  before { stub_const("DisputeEvidence::WEEKEND_EXTENSION_STARTS_AT", Time.utc(9999)) }
end
