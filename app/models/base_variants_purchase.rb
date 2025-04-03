# frozen_string_literal: true

# This table is used as a HABTM join table between BaseVariant and Purchase.
# This model exists to allow us to query for variant ids directly from purchase ids.
# It must not be used directly for creating/deleting records.
class BaseVariantsPurchase < ApplicationRecord
end
