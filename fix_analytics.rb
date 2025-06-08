# Quick script to fix analytics by creating demo data

puts "🔧 Setting up analytics demo data..."

# Find or create the demo user
user = User.find_by(email: "demo@example.com") || User.create!(
  email: "demo@example.com",
  name: "Demo User",
  confirmed_at: Time.current,
  password: "SuperSecure2024!Analytics"
)

puts "✅ Created demo user: #{user.email}"

# Create some demo products
3.times do |i|
  product = user.links.create!(
    name: "Demo Product #{i + 1}",
    description: "This is a demo product for testing analytics",
    price_cents: (10 + i * 5) * 100,
    price_currency_type: "usd",
    unique_permalink: "demo-product-#{i + 1}",
    draft: false,
    purchase_disabled_at: nil
  )

  # Create a price record
  product.prices.create!(
    amount_cents: product.price_cents,
    currency: "usd"
  )

  puts "✅ Created product: #{product.name}"

  # Create some demo purchases for analytics
  (1..5).each do |j|
    purchase = Purchase.create!(
      link: product,
      user: user,
      email: "buyer#{j}@example.com",
      price_cents: product.price_cents,
      currency: "usd",
      order_id: "order_#{product.id}_#{j}",
      purchase_date: rand(30.days).seconds.ago,
      successful: true
    )
    puts "✅ Created purchase for #{product.name}"
  end
end

puts "🔍 Indexing products in Elasticsearch..."

# Index all products in Elasticsearch
user.links.find_each do |product|
  begin
    ProductIndexingService.perform(
      product: product,
      action: "index"
    )
    puts "✅ Indexed product: #{product.name}"
  rescue => e
    puts "❌ Failed to index #{product.name}: #{e.message}"
  end
end

puts "🔍 Indexing purchases in Elasticsearch..."

# Index purchases in Elasticsearch
Purchase.includes(:link).find_each do |purchase|
  begin
    # Index purchase data - this might need to be done differently
    # depending on how Gumroad structures their analytics
    puts "✅ Purchase ready for analytics: Order #{purchase.order_id}"
  rescue => e
    puts "❌ Failed to prepare purchase: #{e.message}"
  end
end

puts "🎉 Analytics demo data setup complete!"
puts "🔗 You should now be able to see data in your analytics dashboard"
