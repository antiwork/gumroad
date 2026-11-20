# frozen_string_literal: true

# Two independent, default-off experiments on the checkout recommendation row. Control is the
# layout and ordering live today; treatment restores the earlier behavior. Arms are a pure function
# of the buyer's browser guid, so any purchase or event carrying that guid can be bucketed in SQL:
#   CRC32(CONCAT('<experiment>:', browser_guid)) % 100 < TREATMENT_PERCENTAGE
module RecommendedProducts::CheckoutExperiment
  TREATMENT_PERCENTAGE = 50

  PHONE_PLACEMENT = "checkout_reco_phone_placement"
  ORDERING = "checkout_reco_ordering"
  EXPERIMENTS = [PHONE_PLACEMENT, ORDERING].freeze

  # Treatment: phone recommendations render above the payment form, in a reserved-height slot.
  def self.phone_placement_treatment?(browser_guid)
    treatment?(PHONE_PLACEMENT, browser_guid)
  end

  # Treatment: co-purchase order instead of paid-first.
  def self.co_purchase_ordering_treatment?(browser_guid)
    treatment?(ORDERING, browser_guid)
  end

  def self.any_active?
    EXPERIMENTS.any? { Feature.active?(_1) }
  end

  def self.treatment?(experiment, browser_guid)
    return false if browser_guid.blank? || !Feature.active?(experiment)

    Zlib.crc32("#{experiment}:#{browser_guid}") % 100 < TREATMENT_PERCENTAGE
  end
  private_class_method :treatment?
end
