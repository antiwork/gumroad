# frozen_string_literal: true

def load_products
  if Rails.env.production?
    puts "Shouldn't run product seeds on production"
    raise
  end
  10.times.each do |i|
    # create seller
    user = User.create!(
      name: "Gumbo #{i}",
      username: "gumbo#{i}",
      email: "gumbo#{i}@gumroad.com",
      password: SecureRandom.hex(24),
      user_risk_state: "compliant",
      confirmed_at: Time.current
    )
    # Skip validations to set a pwned but easy password
    user.password = "password"
    user.save!(validate: false)

    # product
    product = Link.new(
      user_id: user.id,
      name: "Beautiful widget from Gumbo #{i}",
      description: "Description for Gumbo' beautiful magic widgets",
      filetype: "link",
      price_cents: (100 * i),
    )
    product.display_product_reviews = true
    price = product.prices.build(price_cents: product.price_cents)
    price.recurrence = 0
    product.save!

    # create tag
    product.tag!("Tag #{i}")

    # create buyer
    buyer = User.create!(
      name: "Gumbuyer #{i}",
      username: "gumbuyer#{i}",
      email: "gumbuyer#{i}@gumroad.com",
      password: SecureRandom.hex(24),
      user_risk_state: "compliant",
      confirmed_at: Time.current
    )
    # Skip validations to set a pwned but easy password
    buyer.password = "password"
    buyer.save!(validate: false)

    # create purchase
    purchase = Purchase.new(
      link_id: product.id,
      seller_id: user.id,
      price_cents: product.price_cents,
      displayed_price_cents: product.price_cents,
      tax_cents: 0,
      gumroad_tax_cents: 0,
      total_transaction_cents: product.price_cents,
      purchaser_id: buyer.id,
      email: buyer.email,
      card_country: "US",
      ip_address: "199.241.200.176"
    )
    purchase.send(:calculate_fees)
    purchase.save!
    purchase.update_columns(purchase_state: "successful", succeeded_at: Time.current)

    # create review w/ rating
    purchase.post_review(rating: i % 5 + 1)
  end
end

load_products
DevTools.delete_all_indices_and_reindex_all
