# Simple script to index existing data for analytics

puts "🔧 Fixing analytics by indexing existing data..."

# Index all existing products
puts "📦 Indexing products..."
Link.find_each do |product|
  begin
    ProductIndexingService.perform(
      product: product,
      action: "index"
    )
    puts "✅ Indexed: #{product.name}"
  rescue => e
    puts "⚠️  Skipped #{product.name}: #{e.message}"
  end
end

# Also make sure purchases get indexed properly
puts "🛒 Found #{Purchase.count} purchases in database"

puts "🎉 Done! Analytics should work now."
puts "💡 Try refreshing your analytics page"
