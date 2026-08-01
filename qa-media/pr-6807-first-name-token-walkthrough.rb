rows = [
  ["Hi {{first_name}}, thanks!",        {purchase: nil, purchaser_name: "Jordi Bruin"}],
  ["Hi {{first_name}}, thanks!",        {}],
  ["Hi {{first_name|friend}}, thanks!", {}],
  ["Hi {{first_name|friend}}, thanks!", {purchaser_name: "Sahil Lavingia"}],
  ["Thanks everyone!",                  {purchaser_name: "Jordi Bruin"}],
]
puts "recipient name                | template                            | rendered"
puts "-"*110
rows.each do |tpl, r|
  name = r[:purchaser_name] || "(none - e.g. follower or free buyer)"
  fn = PostEmailPersonalization.first_token(r[:purchaser_name])
  puts format("%-28s | %-35s | %s", name, tpl, PostEmailPersonalization.apply(tpl, fn))
end
puts
puts "SendGrid substitution keys for a post using both spellings, name unknown:"
p PostEmailPersonalization.substitutions("{{first_name}} {{first_name|friend}}", nil)
