#!/usr/bin/env ruby

# Script to create test data for reproducing the discount bug
# Run with: rails runner create_test_data.rb

puts "Creating test data for discount bug reproduction..."

user = User.first
puts "Using user: #{user.email}"

begin
  # Create Product A
  product_a = Link.find_or_create_by!(unique_permalink: "producta") do |link|
    link.user = user
    link.name = "Product A"
    link.price_cents = 5000  # $50
    link.suggested_price_cents = 5000
    link.filetype = "link"
    link.filegroup = "url"
    link.native_type = "digital"
    link.discover_fee_per_thousand = 300
  end
  puts "\nProduct A:"
  puts "  ID: #{product_a.id}"
  puts "  Name: #{product_a.name}"
  puts "  Price: $#{product_a.price_cents / 100.0}"
  puts "  Permalink: #{product_a.unique_permalink}"

  # Create Bundle B
  bundle_b = Link.find_or_create_by!(unique_permalink: "bundleb") do |link|
    link.user = user
    link.name = "Bundle B"
    link.price_cents = 15000  # $150
    link.suggested_price_cents = 15000
    link.filetype = "link"
    link.filegroup = "url"
    link.native_type = "bundle"
    link.discover_fee_per_thousand = 300
  end
  puts "\nBundle B:"
  puts "  ID: #{bundle_b.id}"
  puts "  Name: #{bundle_b.name}"
  puts "  Price: $#{bundle_b.price_cents / 100.0}"
  puts "  Permalink: #{bundle_b.unique_permalink}"

  # Add Product A to Bundle B
  bundle_product = BundleProduct.find_or_create_by!(
    bundle_id: bundle_b.id,
    product_id: product_a.id
  ) do |bp|
    bp.quantity = 1
  end
  puts "\nAdded Product A to Bundle B"

  # Use existing discount code or create new one
  discount = OfferCode.find_or_create_by!(code: "HALF50") do |oc|
    oc.amount_percentage = 50
    oc.user = user
  end
  puts "\nDiscount Code:"
  puts "  ID: #{discount.id}"
  puts "  Code: #{discount.code}"
  puts "  Discount: #{discount.amount_percentage}%"

  # Associate products with discount code
  unless discount.products.include?(product_a)
    discount.products << product_a
    puts "  Associated with Product A"
  end
  
  unless discount.products.include?(bundle_b)
    discount.products << bundle_b
    puts "  Associated with Bundle B"
  end

  puts "\n===== TEST DATA SUMMARY ====="
  puts "Product A ID: #{product_a.id}"
  puts "Bundle B ID: #{bundle_b.id}"
  puts "Discount Code: #{discount.code} (#{discount.amount_percentage}% off)"
  puts "Products with discount: #{discount.products.pluck(:name).join(', ')}"
  puts "============================="

  # Save IDs to a file for reference
  File.write('test_data_ids.txt', <<~TXT)
    TEST DATA CREATED AT: #{Time.now}
    
    Product A:
      ID: #{product_a.id}
      Name: #{product_a.name}
      Price: $#{product_a.price_cents / 100.0}
      Permalink: #{product_a.unique_permalink}
    
    Bundle B:
      ID: #{bundle_b.id}
      Name: #{bundle_b.name}
      Price: $#{bundle_b.price_cents / 100.0}
      Permalink: #{bundle_b.unique_permalink}
      Contains: Product A
    
    Discount Code:
      ID: #{discount.id}
      Code: #{discount.code}
      Discount: #{discount.amount_percentage}%
      Applies to: #{discount.products.pluck(:name).join(', ')}
  TXT
  puts "\nTest data IDs saved to test_data_ids.txt"

rescue => e
  puts "\nError creating test data: #{e.message}"
  puts e.backtrace[0..5].join("\n")
end
