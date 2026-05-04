# frozen_string_literal: true

module Onetime
  class SeedDollarStoreProducts
    SELLERS = [
      { name: "Pixel & Co", username: "pixelco" },
      { name: "Lo-fi Lab", username: "lofilab" },
      { name: "Studio Otherwise", username: "studiootherwise" },
      { name: "Beans Press", username: "beanspress" },
      { name: "Garage Goods", username: "garagegoods" },
      { name: "Tiny Atlas", username: "tinyatlas" },
    ].freeze

    PRODUCTS = [
      { name: "Lo-fi guitar loops vol. 1", description: "20 mellow guitar loops for chill beats.", taxonomy: "music-and-sound-design", price: 99 },
      { name: "Synth presets pack", description: "60 vintage analog presets for Serum.", taxonomy: "music-and-sound-design", price: 100 },
      { name: "Late night journaling worksheet", description: "A printable PDF for evening reflection.", taxonomy: "self-improvement", price: 100 },
      { name: "Daily affirmation deck", description: "30 cards to start your morning right.", taxonomy: "self-improvement", price: 99 },
      { name: "Wallpaper of the week", description: "Fresh hand-drawn wallpaper, every week.", taxonomy: "drawing-and-painting", price: 0 },
      { name: "Pixel sparkles brush pack", description: "12 procreate brushes for adding sparkle.", taxonomy: "drawing-and-painting", price: 0 },
      { name: "Coffee shop ambience pack", description: "3 hours of cozy cafe sounds.", taxonomy: "audio", price: 99 },
      { name: "Rain on tin roof loop", description: "10-minute seamless rain loop for focus.", taxonomy: "audio", price: 50 },
      { name: "One dollar zine", description: "A 12-page indie zine, fresh off the press.", taxonomy: "comics-and-graphic-novels", price: 100 },
      { name: "Mini comic: Garbage Day", description: "8-page slice-of-life comic.", taxonomy: "comics-and-graphic-novels", price: 75 },
      { name: "Architecture sketch pack", description: "PDF set of 24 line-work sketches.", taxonomy: "design", price: 100 },
      { name: "Brutalist UI kit", description: "Figma kit, sharp edges, no nonsense.", taxonomy: "design", price: 100 },
      { name: "Icon set: 50 minimal lines", description: "SVG + PNG, 1px stroke, ready to drop in.", taxonomy: "design", price: 99 },
      { name: "Modular wireframe template", description: "120 components for fast prototyping.", taxonomy: "design", price: 100 },
      { name: "1MB CSS reset", description: "A tiny modern CSS reset, MIT licensed.", taxonomy: "software-development", price: 0 },
      { name: "Bash one-liners cheat sheet", description: "PDF reference for daily terminal life.", taxonomy: "software-development", price: 50 },
      { name: "Postgres index recipes", description: "When to use which index, with examples.", taxonomy: "software-development", price: 100 },
      { name: "Unity starter scene", description: "Drop-in scene with lighting + camera rig.", taxonomy: "gaming", price: 100 },
      { name: "Pixel art character pack", description: "16x16 sprites for retro games.", taxonomy: "gaming", price: 99 },
      { name: "Beginner's guide to budgeting", description: "PDF guide, 32 pages.", taxonomy: "business-and-money", price: 100 },
      { name: "Freelance invoice template", description: "Numbers/Excel template, copy & customize.", taxonomy: "business-and-money", price: 50 },
      { name: "Cold email starter pack", description: "10 templates that actually get replies.", taxonomy: "business-and-money", price: 99 },
      { name: "10-minute morning yoga", description: "Quick wake-up flow, video + PDF.", taxonomy: "fitness-and-health", price: 100 },
      { name: "Couch to 5K printable plan", description: "8-week running plan, fits on one page.", taxonomy: "fitness-and-health", price: 0 },
      { name: "Reading log: 100 books", description: "Track your year of reading.", taxonomy: "education", price: 50 },
      { name: "Spanish verbs flashcards", description: "200 PDF flashcards for daily practice.", taxonomy: "education", price: 100 },
      { name: "Astronomy 101 syllabus", description: "Self-study syllabus, 12 weeks.", taxonomy: "education", price: 75 },
      { name: "Short film: Driveway", description: "5-minute experimental short, MP4.", taxonomy: "films", price: 100 },
      { name: "Grain & noise overlays", description: "10 ProRes overlays for film grading.", taxonomy: "films", price: 100 },
      { name: "Sample novel chapter: The Quiet Job", description: "First chapter, free preview.", taxonomy: "fiction-books", price: 0 },
      { name: "Microfiction collection", description: "30 stories under 200 words.", taxonomy: "fiction-books", price: 99 },
      { name: "Travel writing prompts", description: "52 prompts to get you off the page.", taxonomy: "writing-and-publishing", price: 50 },
      { name: "Newsletter starter kit", description: "Plain-text templates that don't suck.", taxonomy: "writing-and-publishing", price: 100 },
      { name: "Lightroom presets: Sunday", description: "8 warm-tone presets for film looks.", taxonomy: "photography", price: 100 },
      { name: "Street photo composition guide", description: "Visual PDF, 40 pages.", taxonomy: "photography", price: 99 },
      { name: "Blender low-poly tree pack", description: "12 stylized trees, blend + fbx.", taxonomy: "3d", price: 100 },
      { name: "3D printable desk organizer", description: "STL files, prints on any FDM.", taxonomy: "3d", price: 50 },
      { name: "Lo-fi piano stems", description: "12 raw stems for your next beat.", taxonomy: "recorded-music", price: 99 },
      { name: "Demo EP: Greenhouse", description: "4-track demo EP, MP3 + WAV.", taxonomy: "recorded-music", price: 100 },
    ].freeze

    def self.process
      new.process
    end

    HIGH_VOLUME_INDICES = [0, 18, 31].freeze
    ZERO_REVIEW_INDICES = [3, 22, 36].freeze
    BUYER_POOL_SIZE = 200

    WRITTEN_REVIEWS = {
      "1MB CSS reset" => [
        { rating: 5, message: "Drop-in replacement for our old reset, shaved 4kb off our CSS bundle." },
        { rating: 5, message: "Finally, a reset that doesn't fight modern browsers. Reads beautifully too." },
        { rating: 4, message: "Solid defaults. Only knocked one star because I'd love a Sass version." },
        { rating: 5, message: "Used this on three projects already. Just works." },
      ]
    }.freeze

    def process
      raise "Don't run on production" if Rails.env.production?

      sellers = SELLERS.map.with_index { |s, i| ensure_seller(s.merge(index: i)) }
      created = 0
      reviews_added = 0

      PRODUCTS.each_with_index do |spec, i|
        seller = sellers[i % sellers.size]
        product = Link.find_by(user_id: seller.id, name: spec[:name])
        if product.nil?
          product = build_product(seller:, spec:, index: i)
          attach_thumbnail(product:, spec:, index: i)
          created += 1
        end
        reviews_added += ensure_sales_and_reviews(product:, index: i)
      end

      DevTools.delete_all_indices_and_reindex_all
      puts "Seeded #{created} new products and #{reviews_added} new reviews across #{sellers.size} sellers."
    end

    private
      def ensure_seller(spec)
        email = "#{spec[:username]}@gumroad-dollar-store.example.com"
        existing = User.find_by(username: spec[:username])
        if existing
          existing.update!(payment_address: email) if existing.payment_address.blank?
          return existing
        end

        user = User.new(
          name: spec[:name],
          username: spec[:username],
          email: email,
          password: SecureRandom.hex(24),
          user_risk_state: "compliant",
          confirmed_at: Time.current,
          payment_address: email,
        )
        user.save!
        user.password = "password"
        user.save!(validate: false)
        user
      end

      def build_product(seller:, spec:, index:)
        price = spec[:price].zero? ? 0 : [spec[:price], 99].max
        product = Link.new(
          user_id: seller.id,
          name: spec[:name],
          description: spec[:description],
          filetype: "link",
          price_cents: price,
        )
        product.display_product_reviews = true
        product.prices.build(price_cents: price, recurrence: 0)
        product.save!

        if (taxonomy = Taxonomy.find_by(slug: spec[:taxonomy].split("/").last))
          product.update!(taxonomy_id: taxonomy.id)
        end

        tag = spec[:taxonomy].titleize
        product.tag!(tag) if tag.length <= 20
        product
      end

      def attach_thumbnail(product:, spec:, index:)
        Thumbnail.create!(
          product: product,
          unsplash_url: "https://picsum.photos/seed/dollar-#{index}-#{spec[:taxonomy]}/600/600",
        )
      end

      def ensure_sales_and_reviews(product:, index:)
        scripted = WRITTEN_REVIEWS[product.name]
        added_written = scripted ? ensure_written_reviews(product:, index:, scripted:) : 0

        target = target_review_count(index)

        if target.zero?
          unless product.sales.counts_towards_volume.exists?
            buyer = ensure_buyer(slot: index % BUYER_POOL_SIZE)
            create_purchase(product:, buyer:, rating: nil)
          end
          return added_written
        end

        existing = product.product_reviews.count
        deficit = target - existing
        return added_written if deficit <= 0

        deficit.times do |n|
          slot = (index * 1000 + existing + n) % BUYER_POOL_SIZE
          buyer = ensure_buyer(slot:)
          create_purchase(product:, buyer:, rating: ((existing + n + index) % 5) + 1)
        end
        added_written + deficit
      end

      def ensure_written_reviews(product:, index:, scripted:)
        added = 0
        scripted.each_with_index do |spec, n|
          slot = (index * 7919 + n) % BUYER_POOL_SIZE
          buyer = ensure_buyer(slot:)
          next if Purchase.exists?(link_id: product.id, purchaser_id: buyer.id)
          create_purchase(product:, buyer:, rating: spec[:rating], message: spec[:message])
          added += 1
        end
        added
      end

      def target_review_count(index)
        return 100 + (index * 17) % 60 if HIGH_VOLUME_INDICES.include?(index)
        return 0 if ZERO_REVIEW_INDICES.include?(index)
        (index % 5) + 1
      end

      def ensure_buyer(slot:)
        username = "dsbuyer#{slot}"
        User.find_or_create_by!(username:) do |u|
          u.name = "Buyer #{slot}"
          u.email = "#{username}@gumroad-dollar-store.example.com"
          u.password = SecureRandom.hex(24)
          u.user_risk_state = "compliant"
          u.confirmed_at = Time.current
        end
      end

      def create_purchase(product:, buyer:, rating:, message: nil)
        purchase = Purchase.new(
          link_id: product.id,
          seller_id: product.user_id,
          price_cents: product.price_cents,
          displayed_price_cents: product.price_cents,
          tax_cents: 0,
          gumroad_tax_cents: 0,
          total_transaction_cents: product.price_cents,
          purchaser_id: buyer.id,
          email: buyer.email,
          card_country: "US",
          ip_address: "199.241.200.176",
        )
        purchase.send(:calculate_fees)
        purchase.save!
        purchase.update_columns(purchase_state: "successful", succeeded_at: Time.current)
        purchase.post_review(rating: rating, message: message) if rating
      end
  end
end
