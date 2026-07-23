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
  if existing.present?
    # Databases seeded before url redirects were added here need the redirect backfilled,
    # otherwise the mobile purchase page has no content to render.
    existing.create_url_redirect! if existing.url_redirect.blank?
    return existing
  end

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
  purchase.create_url_redirect!
  purchase
end

# The mobile app's audio-playback e2e flow (gumroad-mobile .maestro/audio-playback.yaml) needs a
# purchased product with a playable audio file. Uploads a small MP3 fixture to the dev S3 bucket
# and attaches it to the product so the purchase page renders a native play button.
def create_mobile_audio_file(product:)
  existing = product.product_files.alive.find_by(filegroup: "audio")
  return existing if existing.present?

  s3_key = "attachments/mobile_e2e/Mobile Test Audio.mp3"
  s3_object = Aws::S3::Resource.new.bucket(S3_BUCKET).object(s3_key)
  s3_object.upload_file(Rails.root.join("spec", "support", "fixtures", "magic.mp3").to_s) unless s3_object.exists?

  product_file = product.product_files.create!(url: "#{S3_BASE_URL}#{s3_key}")
  product_file.analyze
  product_file
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

create_mobile_audio_file(product: product1)

create_mobile_purchase(seller: seller2, buyer: seller1, product: product2)

create_mobile_purchase(seller: seller1, buyer: buyer, product: product1)
create_mobile_purchase(seller: seller2, buyer: buyer, product: product2)
