# frozen_string_literal: true

# The restored fine-print classifier hits OpenRouter on every RefundPolicy save
# with present fine print. Default it off so factories and unrelated specs
# do not make live calls. Specs that exercise the gate call
# `enable_fine_print_no_refunds_moderation!` and stub the client themselves.
RSpec.configure do |config|
  config.before do
    allow_any_instance_of(RefundPolicy).to receive(:fine_print_claims_no_refunds?).and_return(false)
  end
end

module FinePrintNoRefundsModerationSpecHelpers
  def enable_fine_print_no_refunds_moderation!
    allow_any_instance_of(RefundPolicy).to receive(:fine_print_claims_no_refunds?).and_call_original
  end
end

RSpec.configure do |config|
  config.include FinePrintNoRefundsModerationSpecHelpers
end
