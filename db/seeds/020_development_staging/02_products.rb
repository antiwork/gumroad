# frozen_string_literal: true

product = Link.fetch("demo")
if product.blank?
  # Demo product used on /widgets page for non-logged in users
  seller = User.find_by(email: "seller@gumroad.com")
  seller.products.create!(
    name: "Beautiful widget",
    unique_permalink: "demo",
    description: "Description for demo product",
    filetype: "link",
    price_cents: 0,
  )
end
