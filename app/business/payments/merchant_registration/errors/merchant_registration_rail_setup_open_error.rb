# frozen_string_literal: true

# Raised before any provider call when the seller's managed provisioning belongs to the rail-setup
# flow, so there is no attempt to clean up and no recovery note to touch.
class MerchantRegistrationRailSetupOpenError < MerchantRegistrationUserAlreadyHasAccountError
end
