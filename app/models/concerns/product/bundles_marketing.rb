# frozen_string_literal: true

module Product::BundlesMarketing
  YEAR_BUNDLE = "year"
  BEST_SELLING_BUNDLE = "best_selling"
  EVERYTHING_BUNDLE = "everything"

  BUNDLE_NAMES = {
    YEAR_BUNDLE => "#{1.year.ago.year} Bundle",
    BEST_SELLING_BUNDLE => "Best Selling Bundle",
    EVERYTHING_BUNDLE => "Everything Bundle"
  }.freeze
end
