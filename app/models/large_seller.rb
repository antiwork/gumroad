# frozen_string_literal: true

# This table contains a list of users that have a large number sales.
# It's needed for the performance of the web analytics.
# Note that:
# - This has nothing to do with VIPs / sellers that have a large revenue.
#   This is strictly about the number of `purchases` rows associated with a seller,
#   whether they're free or not.
# - This model/table is destined to be deleted once we get faster analytics
# - This table isn't refreshed automatically, because we rarely need to update it

class LargeSeller < ApplicationRecord
  SALES_LOWER_LIMIT = 1000

  belongs_to :user, optional: true

  def self.create_if_warranted(user)
    return if where(user:).exists?
    sales_count = user.sales.count
    return if sales_count < SALES_LOWER_LIMIT
    create!(user:, sales_count:)
  end
end
