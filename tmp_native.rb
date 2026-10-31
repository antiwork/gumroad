l = Link.where(unique_permalink: "qkicyh").first
puts "NATIVE_TYPE=#{l.native_type.inspect}"
puts "COFFEE_CONST=#{Link::NATIVE_TYPE_COFFEE.inspect}"
puts "IS_COFFEE=#{l.native_type == Link::NATIVE_TYPE_COFFEE}"
puts "CUSTOM_HTML=#{l.custom_html.to_s.length}"
puts "PRODUCT_FILES=#{ProductFile.where(link_id: l.id).count}"
puts "COFFEE_ROUTE=/coffee"
