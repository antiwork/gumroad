
product = Link.last
puts "product=#{product&.id}"
begin
  v = Product::EditorRevision.send(:variant_integration_stamps, product)
  puts "variant_integration_stamps OK => #{v.inspect[0,120]}"
  puts "token=#{Product::EditorRevision.current(product)[0,24]}..."
rescue => e
  puts "ERROR: #{e.class}: #{e.message[0,200]}"
end
