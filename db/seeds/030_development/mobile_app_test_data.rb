# frozen_string_literal: true

# Used by the mobile app e2e test framework. Logging in as these users may break the test expectations.

def create_mobile_user(email:, name:, username:)
  user = User.find_by(email:)
  if user.present?
    user.password = "password"
    user.save!(validate: false)
    return user
  end

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

def create_mobile_product_file(product:, fixture_name:, file_name:)
  s3_key = "attachments/mobile_e2e/#{file_name}"
  url = "#{S3_BASE_URL}#{s3_key}"
  existing = product.product_files.alive.find_by(url:)
  return existing if existing.present?

  s3_object = Aws::S3::Resource.new.bucket(S3_BUCKET).object(s3_key)
  fixture = Rails.root.join("spec", "support", "fixtures", fixture_name)
  s3_object.upload_file(fixture.to_s) unless s3_object.exists?

  product_file = product.product_files.create!(url:)
  product_file.analyze
  product_file
end

# A third-party embed, not an uploaded file: `create_mobile_product_file` covers the native
# player, and nothing here exercised the WebView the embed renders in. The URL has to be a real
# HTTPS one — the content page turns `attrs.url` into an anchor href and RichContent rejects the
# script-bearing schemes, so a placeholder like "embed://x" would not save.
def create_mobile_embed_page(product:, title:)
  # Upsert, not create-if-missing: this page's whole purpose is to hold the mediaEmbed node, so a
  # pre-existing page from an earlier seed run (with different content) must be overwritten rather
  # than left stale, or the fixture silently stops exercising WebView playback.
  page = product.alive_rich_contents.find_or_initialize_by(title:)
  page.update!(
    description: [
      {
        "type" => "mediaEmbed",
        "attrs" => {
          "url" => "https://www.youtube.com/watch?v=YE7VzlLtp-4",
          "title" => "Big Buck Bunny",
          "html" => '<iframe src="https://cdn.iframe.ly/api/iframe?url=https%3A%2F%2Fyoutu.be%2FYE7VzlLtp-4&key=31708e31359468f73bc5b03e9dcab7da" style="top: 0; left: 0; width: 100%; height: 100%; position: absolute; border: 0;" allowfullscreen scrolling="no" allow="accelerometer *; clipboard-write *; encrypted-media *; gyroscope *; picture-in-picture *; web-share *;"></iframe>'
        }
      }
    ]
  )
  page
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

create_mobile_product_file(
  product: product1,
  fixture_name: "magic.mp3",
  file_name: "Mobile Test Audio.mp3"
)
create_mobile_product_file(
  product: product1,
  fixture_name: "Big Buck Bunny - Trailer.mp4",
  file_name: "Mobile Test Video.mp4"
)
create_mobile_product_file(
  product: product1,
  fixture_name: "Alice's Adventures in Wonderland.pdf",
  file_name: "Mobile Test PDF.pdf"
)

create_mobile_purchase(seller: seller2, buyer: seller1, product: product2)

create_mobile_purchase(seller: seller1, buyer: buyer, product: product1)
create_mobile_purchase(seller: seller2, buyer: buyer, product: product2)

embed_course = create_mobile_product(
  user: seller1,
  name: "Mobile Embed Video Course",
  price_cents: 500,
  permalink: "embedvideocourse"
)

create_mobile_embed_page(product: embed_course, title: "Lesson 1")

create_mobile_purchase(seller: seller1, buyer: buyer, product: embed_course)
