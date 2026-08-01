# frozen_string_literal: true

# Synthetic Pages::ProductPrices.build benchmark at MAX_ITEMS = 100 vs 200 (gumroad-private#1522).
#
# The point of the measurement: ProductPrices is the UNCACHED per-request half of a custom
# profile page, so raising MAX_ITEMS raises real work on every render. This measures query
# count and wall time at both caps against one synthetic seller, so the future cost of the
# 200 ceiling is bounded by a number rather than an assumption.
#
#   bin/rails runner -e test script/benchmark_profile_product_prices.rb
require "benchmark"

SELLER_PRODUCTS = 260

def build_seller
  seller = User.create!(
    email: "cap-bench-#{SecureRandom.hex(6)}@example.com",
    username: "capbench#{SecureRandom.hex(4)}",
    password: SecureRandom.hex(12),
    confirmed_at: Time.current,
  )
  # A mix of shapes so the run exercises both pricing branches rather than the cheapest one:
  # plain products take own_currency_entry, versioned products drag the variant preloads that
  # lowest_variant_price_difference_cents needs.
  #
  # bypass_product_creation_limit lifts the 10-per-day cap. Validations must still RUN — the
  # permalink is assigned by a callback on the validated save path, and the built payload is
  # keyed by general_permalink, so skipping validation collapses every product onto one nil key.
  Link.bypass_product_creation_limit do
    SELLER_PRODUCTS.times do |i|
      product = Link.create!(
        user: seller,
        name: "Bench product #{i}",
        price_cents: 1000 + i,
        native_type: "digital",
        purchase_disabled_at: nil,
        draft: false,
      )
      next unless (i % 3).zero?

      category = product.variant_categories.create!(title: "Tier")
      category.variants.create!(name: "Standard", price_difference_cents: 0)
      category.variants.create!(name: "Deluxe", price_difference_cents: 500)
    end
  end
  seller
end

def measure(seller, cap)
  Pages::ProfileData.send(:remove_const, :MAX_ITEMS)
  Pages::ProfileData.const_set(:MAX_ITEMS, cap)

  queries = 0
  counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
  result = nil
  elapsed = nil
  ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
    elapsed = Benchmark.realtime { result = Pages::ProductPrices.build(seller, ip: "8.8.8.8") }
  end
  [cap, result.size, queries, (elapsed * 1000).round(1)]
end

seller = build_seller
eligible = seller.products.alive.not_archived.not_draft.count
puts "seller products (payload-eligible): #{eligible}"

# Warm once and discard: the first call in a process pays constant setup (GeoIP handle, column
# metadata) that would otherwise be charged entirely to whichever cap ran first.
measure(seller, 10)

rows = [100, 200].map { |cap| measure(seller, cap) }
puts format("%-6s %-9s %-9s %s", "cap", "priced", "queries", "ms")
rows.each { |cap, priced, queries, ms| puts format("%-6d %-9d %-9d %s", cap, priced, queries, ms) }

a, b = rows
# Guard against a silently useless run: the payload is keyed by general_permalink, so a fixture
# whose products share (or lack) one collapses into a handful of entries and the timings below
# would describe nothing.
raise "fixture priced #{a[1]}/#{b[1]} entries, expected 100/200 — check permalink uniqueness" \
  unless a[1] == 100 && b[1] == 200

puts format("delta 100->200: priced +%d, queries +%d, ms +%.1f (%.2fx)",
            b[1] - a[1], b[2] - a[2], b[3] - a[3], b[3] / a[3])
