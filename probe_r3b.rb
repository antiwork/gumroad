
ActiveRecord::Base.transaction do
  user = User.create!(email: "r3-#{SecureRandom.hex(4)}@example.com", password: SecureRandom.hex(8), username: "r3#{SecureRandom.hex(4)}")
  product = Link.create!(user: user, name: "R3 probe", price_cents: 100, native_type: "digital")
  cat = VariantCategory.create!(link: product, title: "Versions")
  v1 = Variant.create!(variant_category: cat, name: "V1")
  integ = DiscordIntegration.create!(server_id: "0", server_name: "Gaming", username: "gumbot")

  before = Product::EditorRevision.current(product.reload)
  BaseVariantIntegration.create!(base_variant: v1, integration: integ)
  after = Product::EditorRevision.current(product.reload)

  puts "BEFORE=#{before[0,16]}"
  puts "AFTER =#{after[0,16]}"
  puts(before == after ? "FAIL: token did NOT change when a variant integration was enabled" : "PASS: token changed -> stale tab now detected")
  raise ActiveRecord::Rollback
end
