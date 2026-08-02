# frozen_string_literal: true

# PR 6787 seed, corrected. Three arms — the PR body argues the third is redundant
# because it renders identically to arm B; that is verified here rather than assumed.
#   demo            -> reviews SHOWN,  4 reviews avg 4.5      (real values written)
#   membershipdemo  -> reviews HIDDEN, 3 reviews exist        (fallback survives, nothing leaks)
#   QA6787 Widget C -> reviews SHOWN,  ZERO reviews           (fallback survives)
#
# ProductReview.create! already updates the product's stat row through its own
# callback — calling update_review_stat_via_rating_change on top of it double-counts
# (a first pass produced count=8 for four reviews).

M = "MARK6787S2"
def m(s) = puts("#{M} #{s}")

s = User.find_by(email: "seller@gumroad.com")
Feature.activate_user(:custom_html_pages, s)
m "flag_custom_html_pages=#{Feature.active?(:custom_html_pages, s)}"

HTML = <<~HTML
  <div class="p-10 font-sans">
    <div id="arm" class="mb-6 bg-black text-white px-4 py-2 text-sm">ARM_LABEL</div>
    <h1 class="text-3xl font-bold" data-gumroad-field="name">PRODUCT NAME PLACEHOLDER</h1>
    <div class="text-xl mt-2" data-gumroad-field="price">PRICE PLACEHOLDER</div>
    <div class="mt-8 border-t pt-6">
      <div class="text-sm uppercase tracking-wide text-gray-500 mb-2">Customer reviews</div>
      <div class="text-4xl font-bold">
        <span data-gumroad-field="rating">Be the first to review</span>
        <span class="text-lg font-normal text-gray-600">
          out of 5 &middot; <span data-gumroad-field="review-count">no</span> reviews
        </span>
      </div>
    </div>
    <div class="mt-8 text-gray-700" data-gumroad-field="description">DESCRIPTION PLACEHOLDER</div>
  </div>
HTML

def seed_page(link, label)
  html = HTML.sub("ARM_LABEL", label)
  row = Page.where(pageable_type: "Link", pageable_id: link.id).find { |r| r.slug.nil? }
  row ||= Page.new(pageable: link)
  row.save!(validate: false) if row.new_record?
  row.update_column(:custom_html, html)
  Link.find(link.id).reload.custom_html.to_s.length
end

def reset_reviews(link)
  # ProductReview#destroy rolls back on this build (the product_review_videos
  # association guard fires), so delete the rows and drop the stat row instead.
  ProductReview.where(link_id: link.id).delete_all
  link.reload.product_review_stat&.delete
  link.reload
end

def seed_reviews(link, seller, ratings)
  reset_reviews(link)
  ratings.each_with_index do |rating, i|
    p = link.sales.build(seller:, email: "qa6787+#{link.id}-#{i}-#{SecureRandom.hex(2)}@example.com",
                         price_cents: link.price_cents, displayed_price_cents: link.price_cents,
                         purchase_state: "successful", full_name: "QA6787 Buyer #{i}",
                         tax_cents: 0, gumroad_tax_cents: 0)
    p.save!(validate: false)
    ProductReview.create!(purchase: p, link: link, rating: rating, message: "QA6787 review #{i}")
  end
  link.reload.rating_stats
end

demo = Link.find_by(unique_permalink: "demo")
memb = Link.find_by(unique_permalink: "membershipdemo")

c = s.links.alive.find_by(name: "QA6787 Widget C")
if c.nil?
  c = Link.new(user: s, name: "QA6787 Widget C", description: "QA6787 zero-reviews arm",
               price_cents: 1500, native_type: "digital", price_currency_type: "usd")
  c.save!
  c.publish!
end

# ARM A — shown, 4 reviews (5,5,4,4 => 4.5, so the frame carries a non-integer average).
demo.display_product_reviews = true
demo.save!(validate: false)
m "A page_len=#{seed_page(demo, 'ARM A — display_product_reviews = TRUE, 4 reviews')}"
sa = seed_reviews(demo, s, [5, 5, 4, 4])
m "A stats=#{sa.inspect} display=#{demo.reload.display_product_reviews?}"
raise "ABORT arm A count is #{sa[:count]}, expected 4" unless sa[:count] == 4
raise "ABORT arm A average is #{sa[:average]}, expected 4.5" unless sa[:average] == 4.5

# ARM B — HIDDEN with real reviews. The load-bearing negative: nothing may leak.
memb.display_product_reviews = false
memb.save!(validate: false)
m "B page_len=#{seed_page(memb, 'ARM B — display_product_reviews = FALSE, 3 reviews exist')}"
sb = seed_reviews(memb, s, [5, 3, 1])
m "B stats=#{sb.inspect} display=#{memb.reload.display_product_reviews?}"
raise "ABORT arm B has no reviews to hide" unless sb[:count] == 3
raise "ABORT arm B must yield nil" unless Pages::Interpolator.review_summary(memb.reload).nil?

# ARM C — SHOWN but zero reviews. The body claims this renders identically to B.
c.display_product_reviews = true
c.save!(validate: false)
reset_reviews(c)
m "C page_len=#{seed_page(c, 'ARM C — display_product_reviews = TRUE, ZERO reviews')}"
sc = c.reload.rating_stats
m "C stats=#{sc.inspect} display=#{c.reload.display_product_reviews?} perm=#{c.unique_permalink}"
raise "ABORT arm C should have zero reviews" unless sc[:count].zero?
raise "ABORT arm C must yield nil" unless Pages::Interpolator.review_summary(c.reload).nil?

m "A summary=#{Pages::Interpolator.review_summary(demo.reload).inspect}"
m "B summary=#{Pages::Interpolator.review_summary(memb.reload).inspect}"
m "C summary=#{Pages::Interpolator.review_summary(c.reload).inspect}"

# Render each through the real service and compare the review REGION across arms.
regions = {}
[demo, memb, c].each do |l|
  l.reload
  out = Pages::Interpolator.interpolate(l.custom_html, product: l)
  region = out[/Customer reviews.*?<\/div>\s*<\/div>/m].to_s.gsub(/\s+/, " ")
  regions[l.unique_permalink] = region
  m "RENDER #{l.unique_permalink} region=#{region[0, 240].inspect}"
  m "RENDER #{l.unique_permalink} wrote_rating=#{!region.include?('Be the first to review')}"
end
m "IDENTICAL_B_C=#{regions['membershipdemo'] == regions[c.unique_permalink]}"

# Memoization pin (the Greptile P1 the head commit closes): a page repeating the
# markers must aggregate once. Count the calls.
calls = 0
orig = Pages::Interpolator.method(:review_summary)
Pages::Interpolator.singleton_class.send(:define_method, :review_summary) do |product|
  calls += 1
  orig.call(product)
end
repeated = HTML.sub("ARM_LABEL", "memo") +
  %(<span data-gumroad-field="rating">x</span><span data-gumroad-field="review-count">y</span>) * 4
Pages::Interpolator.interpolate(repeated, product: demo.reload)
Pages::Interpolator.singleton_class.send(:define_method, :review_summary, orig)
m "MEMO markers=10 review_summary_calls=#{calls}"
raise "ABORT summary computed #{calls} times for one render" unless calls == 1

m "URLS a=#{demo.long_url} b=#{memb.long_url} c=#{c.long_url}"
m "DONE"
