l = Link.where(unique_permalink: "qkicyh").first
puts "PRICE_CENTS=#{l.price_cents} CUSTOMIZABLE=#{l.customizable_price} CURRENCY=#{l.price_currency_type}"
puts "FORMATTED=#{l.price_formatted_verbose rescue 'n/a'}"
puts "SUGGESTED=#{(l.suggested_price_cents rescue 'n/a')}"
puts "VARIANTS=#{l.skus.alive.map { |s| [s.name, s.price_cents] }.inspect if l.respond_to?(:skus)}"
puts "FILES=#{l.alive_product_files.count rescue 'n/a'}"
puts "UPDATED_AT=#{l.updated_at}"
