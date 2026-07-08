# frozen_string_literal: true

# A published membership product for exercising subscription checkout flows (e.g. the Apple Pay
# recurring payment sheet) on staging and preview apps, where creating one by hand is blocked:
# publishing from the UI reindexes the product synchronously, which fails on preview apps
# (Elasticsearch auth against the shared staging cluster). Creating the product here skips the
# publish action entirely — products are born published (draft: false), so it is purchasable at
# its direct URL without ever being indexed.
#
# find_by (not Link.fetch, which scopes to visible) keeps re-runs idempotent even if the product
# gets soft-deleted.
seller = User.find_by(email: "seller@gumroad.com")
if seller.present? && Link.find_by(unique_permalink: "membershipdemo").blank?
  seller.products.create!(
    name: "Beautiful membership",
    unique_permalink: "membershipdemo",
    description: "Monthly membership used for testing subscription checkout flows",
    filetype: "link",
    native_type: Link::NATIVE_TYPE_MEMBERSHIP,
    is_recurring_billing: true,
    is_tiered_membership: true,
    subscription_duration: :monthly,
    price_cents: 500,
  )
end
