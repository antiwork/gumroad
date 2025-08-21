# frozen_string_literal: true

def find_or_create_recommendable_user(category_name)
  user = User.find_by(email: "gumbo_#{category_name}@gumroad.com")
  return user if user

  user = User.create!(
    name: "Gumbo #{category_name}",
    username: "gumbo#{category_name}",
    email: "gumbo_#{category_name}@gumroad.com",
    password: SecureRandom.hex(24),
    user_risk_state: "compliant",
    confirmed_at: Time.current,
    payment_address: "gumbo_#{category_name}@gumroad.com"
  )

  # Skip validations to set a pwned but easy password
  user.password = "password"
  user.save!(validate: false)

  user
end

def find_or_create_universal_free_offer_code_for(seller)
  offer_code = seller.offer_codes
    .universal
    .alive
    .find_by(amount_percentage: 100)
  return offer_code if offer_code.present?

  OfferCode.create!(
    user: seller,
    universal: true,
    amount_percentage: 100,
    code: "seed-#{seller.id}-#{SecureRandom.hex(3)}"
  )
end

def create_purchase(seller, buyer, product)
  purchase = Purchase.new(
    link_id: product.id,
    seller_id: seller.id,
    price_cents: 0,
    displayed_price_cents: 0,
    tax_cents: 0,
    gumroad_tax_cents: 0,
    total_transaction_cents: 0,
    purchaser_id: buyer.id,
    email: buyer.email,
    card_country: "US",
    ip_address: "199.241.200.176",
    offer_code: find_or_create_universal_free_offer_code_for(seller)
  )
  purchase.send(:calculate_fees)
  purchase.save!
  purchase.update!(purchase_state: "successful", succeeded_at: Time.current)

  purchase.post_review(rating: 3)
end

def create_recommendable_product_if_not_exists(user, taxonomy_slug)
  product_name = "Beautiful #{taxonomy_slug} widget"
  product = user.links.find_by(name: product_name)

  return if product.present?

  product = user.links.create!(
    name: product_name,
    description: "Description for demo product",
    filetype: "link",
    price_cents: 500,
    taxonomy: Taxonomy.find_by(slug: taxonomy_slug),
    display_product_reviews: true
  )
  product.tag!(taxonomy_slug[0..19])

  buyer = User.find_by(email: "seller@gumroad.com")
  create_purchase(user, buyer, product)
end

create_recommendable_product_if_not_exists(find_or_create_recommendable_user("film"), "films")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("music"), "music-and-sound-design")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("writing"), "writing-and-publishing")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("education"), "education")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("software"), "software-development")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("comics"), "comics-and-graphic-novels")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("drawing"), "drawing-and-painting")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("animation"), "3d")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("audio"), "audio")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("games"), "gaming")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("photography"), "photography")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("crafts"), "self-improvement")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("design"), "design")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("sports"), "fitness-and-health")
create_recommendable_product_if_not_exists(find_or_create_recommendable_user("merchandise"), "fiction-books")

DevTools.delete_all_indices_and_reindex_all
