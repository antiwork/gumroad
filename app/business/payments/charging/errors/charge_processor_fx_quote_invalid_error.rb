# frozen_string_literal: true

# Raised when Stripe rejects a PaymentIntent create or confirm because the locked FX quote
# expired or drift-invalidated (market rate moved beyond Stripe's tolerance before
# lock_expires_at). Checkout must re-quote rather than charge a different amount than the
# locked total the buyer last saw.
class ChargeProcessorFxQuoteInvalidError < ChargeProcessorError
end
