# frozen_string_literal: true

# Used by the mobile app e2e test framework. Logging in as these users may break the test expectations.

def create_mobile_user(email:, name:, username:)
  user = User.find_by(email:)
  return user if user.present?

  user = User.create!(
    email:,
    name:,
    username:,
    password: SecureRandom.hex(24),
    user_risk_state: "compliant",
    confirmed_at: Time.current
  )
  user.password = "password"
  user.save!(validate: false)
  user
end

def create_mobile_product(user:, name:, price_cents:, permalink:)
  existing = Link.find_by(unique_permalink: permalink)
  return existing if existing.present?

  product = Link.new(
    user_id: user.id,
    name:,
    description: "Test product for mobile app testing. Do not edit.",
    filetype: "link",
    price_cents:,
    unique_permalink: permalink
  )
  product.display_product_reviews = true
  price = product.prices.build(price_cents: product.price_cents)
  price.recurrence = 0
  product.save!
  product
end

def create_mobile_purchase(seller:, buyer:, product:)
  existing = Purchase.find_by(link_id: product.id, purchaser_id: buyer.id, purchase_state: "successful")
  return existing if existing.present?

  purchase = Purchase.new(
    link_id: product.id,
    seller_id: seller.id,
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
  purchase
end

seller1 = create_mobile_user(
  email: "mobile_seller1_do_not_edit@gumroad.com",
  name: "Mobile Seller 1",
  username: "mobileseller1"
)

seller2 = create_mobile_user(
  email: "mobile_seller2_do_not_edit@gumroad.com",
  name: "Mobile Seller 2",
  username: "mobileseller2"
)

buyer = create_mobile_user(
  email: "mobile_buyer_do_not_edit@gumroad.com",
  name: "Mobile Buyer",
  username: "mobilebuyer"
)

product1 = create_mobile_product(
  user: seller1,
  name: "Mobile Test Product 1",
  price_cents: 500,
  permalink: "firstmobileproduct"
)

product2 = create_mobile_product(
  user: seller2,
  name: "Mobile Test Product 2",
  price_cents: 1000,
  permalink: "secondmobileproduct"
)

create_mobile_purchase(seller: seller2, buyer: seller1, product: product2)

create_mobile_purchase(seller: seller1, buyer: buyer, product: product1)
create_mobile_purchase(seller: seller2, buyer: buyer, product: product2)
