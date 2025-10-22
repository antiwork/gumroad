# frozen_string_literal: true

require "spec_helper"

describe "Product::Searchable - Search scenarios" do
  before do
    @product = create(:product_with_files)
  end

  describe "Elasticsearch `search`" do
    describe "on indexed products with price values" do
      before do
        @creator = create(:recommendable_user)
        product_ids = []
        9.times do |i|
          # The products get slightly more expensive
          # We choose 99 cents and up so we can filter for price less than and greater than $1
          product = create(:product, :recommendable, price_cents: 99 + i, user: @creator)

          # People love buying the cheapest products though! The cheapest
          # products have the highest sales volume.
          (10 - i).times do
            create(:purchase, :with_review, link: product)
          end

          product_ids << product.id
        end

        free_product = create(:product, :recommendable, price_cents: 0, user: @creator)
        product_ids << free_product

        decimal_product = create(:product, :recommendable, price_cents: 550, user: @creator)
        product_ids << decimal_product

        improved_visibility_product = create(:product, :recommendable, discover_fee_per_thousand: 300, price_cents: 200, user: @creator)
        product_ids << improved_visibility_product

        @product_query = Link.where(id: product_ids)

        index_model_records(Purchase)
        index_model_records(Link)
      end

      it "filters by min price" do
        # Filtering for products costing 100 cents or more
        params = { min_price: 1 }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records

        expected_filtered = @product_query.where("price_cents >= ?", 100)
        expected = expected_filtered.sort_by(&:total_fee_cents)
                                    .reverse
                                    .first(9)
                                    .map(&:id)

        # There are 9 products match, costing 100 - 107 (inclusive) cents
        expect(expected).to eq(records.map(&:id))
      end

      it "filters by max price" do
        # Filtering for products costing 100 cents or less
        params = { max_price: 1 }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records

        expected_filtered = @product_query.where("price_cents <= ?", 100)
        expected = expected_filtered.sort_by(&:total_fee_cents)
                                    .reverse
                                    .map(&:id)

        # There are 3 products that match, costing 0, 99 and 100 cents
        expect(expected).to eq(records.map(&:id))
      end

      it "filters by min and max price" do
        # Filtering for products costing exactly 100 cents
        params = { min_price: 1, max_price: 1 }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records

        expected = @product_query.where("price_cents = ?", 100).pluck(:id)

        # There should just be one record that costs exactly 100 cents
        assert_equal 1, records.length
        assert_equal expected, records.map(&:id)
      end

      it "filters when min and max price are 0" do
        # Filtering for products are free
        params = { min_price: 0, max_price: 0 }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records

        expected = @product_query.where("price_cents = ?", 0).pluck(:id)

        # There should just be one record that is free
        assert_equal 1, records.length
        assert_equal expected, records.map(&:id)
      end

      it "min and max filter include products with a decimal price" do
        # Filtering for products costing between $5 and $6
        params = { min_price: 5, max_price: 6 }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records

        expected = @product_query
                       .where("price_cents >= ?", 500)
                       .where("price_cents <= ?", 600)
                       .pluck(:id)

        # There should just be one record in that range that costs $5.50
        assert_equal 1, records.length
        assert_equal expected, records.map(&:id)
      end

      describe "is_alive_on_profile" do
        let(:seller) { create(:user) }
        let!(:product) { create(:product, user: seller) }
        let!(:deleted_product) { create(:product, user: seller, deleted_at: Time.current) }
        let!(:archived_product) { create(:product, user: seller, archived: true) }

        before do
          index_model_records(Link)
        end

        it "filters by is_alive_on_profile" do
          records = Link.search(Link.search_options({ is_alive_on_profile: true, user_id: seller.id })).records
          expect(records.map(&:id)).to eq([product.id])
          records = Link.search(Link.search_options({ is_alive_on_profile: false, user_id: seller.id })).records
          expect(records.map(&:id)).to eq([deleted_product.id, archived_product.id])
        end
      end

      it "sorts by price ascending" do
        params = { sort: ProductSortKey::PRICE_ASCENDING }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records
        expected = @product_query.order(:price_cents).limit(9).pluck(:id)

        assert_equal expected, records.map(&:id)
      end

      it "sorts by price descending" do
        params = { sort: ProductSortKey::PRICE_DESCENDING }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records
        expected = @product_query.order(price_cents: :desc).limit(9).pluck(:id)

        assert_equal expected, records.map(&:id)
      end

      it "sorts by fee revenue and sales volume" do
        search_options = Link.search_options({ sort: ProductSortKey::FEATURED })
        records = Link.search(search_options).records

        expected = @product_query.sort_by(&:total_fee_cents)
                                 .reverse
                                 .first(9)
                                 .map(&:id)

        expect(expected).to eq(records.map(&:id))
      end

      it "sorts by fee revenue and sales volume when no sort param is present" do
        search_options = Link.search_options({})
        records = Link.search(search_options).records

        expected = @product_query.sort_by(&:total_fee_cents)
                                 .reverse
                                 .first(9)
                                 .map(&:id)

        expect(expected).to eq(records.map(&:id))
      end

      it "filters by ID" do
        id = @product_query.first.id
        search_options = Link.search_options({ exclude_ids: [id] })

        records = Link.search(search_options).records.records
        expect(records.map(&:id)).to_not include(id)
      end

      context "when sorting by curated" do
        it "boosts recommended products then sorts by price ascending" do
          recommended_product1 = create(:product, :recommendable)
          recommended_product2 = create(:product, :recommendable)
          recommended_product3 = create(:product, :recommendable)

          Link.import(refresh: true, force: true)

          search_options = Link.search_options({ sort: ProductSortKey::CURATED, curated_product_ids: [recommended_product1.id, recommended_product2.id, recommended_product3.id] })
          records = Link.search(search_options).records

          expect(records.map(&:id)).to eq(
            [
              recommended_product1.id,
              recommended_product2.id,
              recommended_product3.id,
              *@product_query.sort_by(&:total_fee_cents)
                            .reverse
                            .first(6)
                            .map(&:id)
            ]
          )
        end
      end
    end

    describe "on indexed products with filetypes" do
      before do
        @creator = create(:recommendable_user)

        non_recommendable_product = create(:product, name: "non-recommendable product", user: @creator)
        create(:product_file, link: non_recommendable_product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/nyt.pdf")
        create(:product_file, link: non_recommendable_product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3")

        @pdf_product = create(:product, :recommendable, name: "PDF product", user: @creator)
        create(:product_file, link: @pdf_product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/nyt.pdf")

        @mp3_product = create(:product, :recommendable, name: "MP3 product", user: @creator)
        create(:product_file, link: @mp3_product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3")

        @adult_mp3_product = create(:product, :recommendable, user: @creator, is_adult: true)
        create(:product_file, link: @adult_mp3_product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3")

        Link.import(refresh: true, force: true)
      end

      it "filters by one filetype" do
        # Filtering for products with a PDF
        params = { filetypes: "pdf" }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records

        expected = [@pdf_product.id]

        # There should just be one record that has a PDF
        assert_equal 1, records.length
        assert_equal expected, records.map(&:id)
      end

      it "filters by multiple filetypes" do
        # Filtering for products with both a PDF and an MP3
        params = { filetypes: ["pdf", "mp3"] }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records

        expected = [@mp3_product.id, @pdf_product.id]

        # There should be two records that have both
        assert_equal 2, records.length
        assert_equal expected.sort, records.map(&:id).sort
      end

      it "aggregates the filetypes for all params passed, except filetypes" do
        params = { taxonomy_id: Taxonomy.find_by(slug: "films").id, filetypes: ["mp3"] }
        search_options = Link.filetype_options(params)

        aggregations = Link.search(search_options).aggregations["filetypes.keyword"]["buckets"]

        expected = [
          { "key": "mp3", "doc_count": 1 },
          { "key": "pdf", "doc_count": 1 }
        ]

        assert_equal expected, aggregations.map { |key| key.to_h.symbolize_keys }
      end
    end

    describe "top creators aggregation" do
      let(:taxonomy) { Taxonomy.find_by(slug: "3d") }
      let!(:product_1) { create(:product, :recommendable) }
      let!(:product_2) { create(:product, :recommendable) }
      let!(:product_3) { create(:product, :recommendable, taxonomy:) }
      let!(:product_4) { create(:product, :recommendable) }
      let!(:product_5) { create(:product, :recommendable, taxonomy:) }
      let!(:product_6) { create(:product, :recommendable) }
      let!(:product_7) { create(:product, :recommendable) }

      before do
        3.times { create(:purchase, link: product_7) }
        2.times { create(:purchase, link: product_6) }
        create(:purchase, link: product_5)
        3.times { create(:purchase, link: product_4, created_at: 4.months.ago) }

        index_model_records(Purchase)
        index_model_records(Link)
      end

      it "aggregates the top 6 creators by sales volume from the last 3 months" do
        options = Link.search_options({ include_top_creators: true })
        aggregations = Link.search(options)
                           .aggregations
                           .dig("top_creators", "buckets")

        expect(aggregations).to eq([
          { doc_count: 1, key: product_7.user_id, sales_volume_sum: { value: 400.0 } },
          { doc_count: 1, key: product_6.user_id, sales_volume_sum: { value: 300.0 } },
          { doc_count: 1, key: product_5.user_id, sales_volume_sum: { value: 200.0 } },
          { doc_count: 1, key: product_1.user_id, sales_volume_sum: { value: 100.0 } },
          { doc_count: 1, key: product_2.user_id, sales_volume_sum: { value: 100.0 } },
          { doc_count: 1, key: product_3.user_id, sales_volume_sum: { value: 100.0 } },
        ].as_json)
      end

      it "filters top creators by search options" do
        options = Link.search_options({ taxonomy_id: taxonomy.id, include_top_creators: true })
        aggregations = Link.search(options)
                           .aggregations
                           .dig("top_creators", "buckets")

        expect(aggregations).to eq([
          { doc_count: 1, key: product_5.user_id, sales_volume_sum: { value: 200.0 } },
          { doc_count: 1, key: product_3.user_id, sales_volume_sum: { value: 100.0 } },
        ].as_json)
      end

      it "does not include top creators if include_top_creators param is not present" do
        options = Link.search_options({})
        aggregations = Link.search(options).aggregations
        expect(aggregations["top_creators"]).to be_nil
      end
    end

    describe "on indexed products with tags" do
      before do
        creator = create(:compliant_user)
        @durian = create(:product, :recommendable, user: creator)
        @durian.tag!("fruit")
        @celery = create(:product, :recommendable, user: creator)
        @celery.tag!("vegetable")
        @flf = create(:product, :recommendable, user: creator)
        @flf.tag!("house plant")

        Link.import(refresh: true, force: true)
      end

      it "filters by one tag" do
        params = { tags: ["fruit"] }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records

        assert_equal 1, records.length
        assert_equal [@durian.id], records.map(&:id)
      end

      it "filters to the union of two tags" do
        params = { tags: ["fruit", "vegetable"] }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records

        assert_equal 2, records.length
        assert_equal [@celery.id, @durian.id].sort, records.map(&:id).sort
      end
    end

    describe "on indexed products with `created_at` value" do
      it "sorts by newest" do
        creator = create(:compliant_user, username: "username")
        time = Time.current
        product_ids = []

        18.times do |i|
          # Ensure that each created_at is distinct
          travel_to(time + i.minutes) do
            product = create(:product, :recommendable, user: creator)
            product_ids << product.id
          end
        end

        Link.import(refresh: true, force: true)

        params = { sort: ProductSortKey::NEWEST }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records.map(&:id)
        expected = Link.where(id: product_ids).order(created_at: :desc).limit(9).pluck(:id)

        assert_equal expected, records
      end
    end

    describe "searching by section" do
      before do
        @creator = create(:user)
        product_a = create(:product, :recommendable, user: @creator)
        product_b = create(:product, :recommendable, user: @creator)
        product_c = create(:product, :recommendable, user: @creator)
        product_d = create(:product, :recommendable, user: @creator)
        create(:product, :recommendable, user: @creator)
        Link.import(refresh: true, force: true)
        @products = [product_b, product_a, product_d, product_c]
      end

      it "returns only the products in the given section, in the correct order" do
        section = create(:seller_profile_products_section, seller: @creator, shown_products: @products.map { _1.id })
        search_options = Link.search_options({ user_id: @creator.id, section:, sort: "page_layout" })
        records = Link.search(search_options).records
        expected = @products.map(&:unique_permalink)
        assert_equal expected, records.map(&:unique_permalink)
      end
    end

    describe "on indexed products with reviews" do
      before do
        creator = create(:compliant_user, username: "username")
        product_ids = []
        time = Time.current

        9.times do |i|
          travel_to(time + i.seconds) do
            product = create(:product, :with_films_taxonomy, user: creator)

            # Purchase the product and review it
            i.times do
              purchase = create(:purchase, link: product)
              create(:product_review, purchase:, rating: 1 + (i % 4))
            end

            product_ids << product.id
          end
        end

        # Add 2 products with the same rating
        travel_to(time) do
          product = create(:product, :with_films_taxonomy, user: creator,)
          2.times do
            purchase = create(:purchase, link: product)
            create(:product_review, purchase:, rating: 4)
          end
          product_ids << product.id

          product = create(:product, :with_films_taxonomy, user: creator,)
          purchase = create(:purchase, link: product)
          create(:product_review, purchase:, rating: 4)
          product_ids << product.id
        end

        @products_query = Link.where(id: product_ids)
        Link.import(refresh: true, force: true)
      end

      it "sorts by most reviewed product" do
        params = { sort: ProductSortKey::MOST_REVIEWED }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records

        # Sort by review count and created at, but *ascending*
        expected_ascending = @products_query.sort_by do |product|
          [product.reviews_count, product.created_at]
        end

        # Reverse to get them descending, and then grab the first 9 results
        expected = expected_ascending.reverse[0..8]

        assert_equal expected.map(&:id), records.map(&:id)
      end

      it "sorts and filters by average rating" do
        params = { sort: ProductSortKey::HIGHEST_RATED, rating: 2 }
        search_options = Link.search_options(params)
        records = Link.search(search_options).records

        # Filter for sufficient average rating
        expected_filtered = @products_query.select { |product| product.average_rating >= 2 }
        # Sort by average rating and created at, but *ascending*
        expected_ascending = expected_filtered.sort_by do |product|
          [product.average_rating, product.reviews_count, product.created_at]
        end

        # Reverse to get them descending, and then grab the first 9 results
        expected = expected_ascending.reverse[0..8]

        assert_equal expected.map(&:id), records.map(&:id)
      end
    end

    describe "on all products with reviews_count" do
      before do
        creator = create(:compliant_user, name: "Gumbot")
        @product_1 = create(:product, :with_films_taxonomy, user: creator,)
        create(:product_review, purchase: create(:purchase, link: @product_1))
        create(:product_review, purchase: create(:purchase, link: @product_1))
        @product_2 = create(:product, :with_films_taxonomy, user: creator,)
        create(:product_review, purchase: create(:purchase, link: @product_2))
        @product_3 = create(:product, :with_films_taxonomy, user: creator,)
        Link.import(refresh: true, force: true)
      end

      it "filters products with reviews_count greater than min_reviews_count" do
        search_options_1 = Link.search_options(min_reviews_count: 1)
        results_1 = Link.search(search_options_1).records
        expect(results_1).to include @product_1
        expect(results_1).to include @product_2
        expect(results_1).to_not include @product_3
        search_options_2 = Link.search_options(min_reviews_count: 2)
        results_2 = Link.search(search_options_2).records
        expect(results_2).to include @product_1
        expect(results_2).to_not include @product_2
        expect(results_2).to_not include @product_3
      end
    end

    describe "on indexed products with taxonomy set" do
      before do
        @films = Taxonomy.find_by(slug: "films")
        @comedy = Taxonomy.find_by(slug: "comedy", parent: @films)
        @standup = Taxonomy.find_by(slug: "standup", parent: @comedy)
        @music = Taxonomy.find_by(slug: "music-and-sound-design")

        @product_1 = create(:product, :recommendable, name: "top music", taxonomy: @music)
        @product_2 = create(:product, :recommendable, name: "top film", taxonomy: @standup)
        Link.import(refresh: true, force: true)
      end

      it "returns products with matching taxonomy" do
        search_options_1 = Link.search_options(taxonomy_id: @music.id)
        results_1 = Link.search(search_options_1).records
        expect(results_1).to include @product_1
        expect(results_1).to_not include @product_2

        search_options_2 = Link.search_options(taxonomy_id: @standup.id)
        results_2 = Link.search(search_options_2).records
        expect(results_2).to include @product_2
        expect(results_2).to_not include @product_1
      end

      it "does not return descendant products" do
        search_options_1 = Link.search_options(taxonomy_id: @comedy.id)
        results_1 = Link.search(search_options_1).records
        expect(results_1.length).to eq(0)

        search_options_2 = Link.search_options(taxonomy_id: @films.id)
        results_2 = Link.search(search_options_2).records
        expect(results_2.length).to eq(0)
      end

      describe "when include_taxonomy_descendants params is true" do
        it "returns products whose taxonomy is a child of the set taxonomy" do
          search_options = Link.search_options(
            taxonomy_id: @comedy.id,
            include_taxonomy_descendants: true
          )
          results = Link.search(search_options).records
          expect(results).to include @product_2
          expect(results).to_not include @product_1
        end

        it "returns products whose taxonomy is the grandchildren of the set taxonomy" do
          search_options = Link.search_options(
            taxonomy_id: @films.id,
            include_taxonomy_descendants: true
          )
          results = Link.search(search_options).records
          expect(results).to include @product_2
          expect(results).to_not include @product_1
        end
      end
    end

    describe "on indexed products rated as adult" do
      before do
        @product_sfw = create(:product, :recommendable)
        @product_nsfw = create(:product, :recommendable, is_adult: true)
        index_model_records(Link)
      end

      it "excludes adult products when include_rated_as_adult is absent" do
        search_options = Link.search_options({})
        results = Link.search(search_options).records
        expect(results).to include @product_sfw
        expect(results).to_not include @product_nsfw
      end

      it "includes adult products when include_rated_as_adult is present" do
        search_options = Link.search_options(include_rated_as_adult: true)
        results = Link.search(search_options).records
        expect(results).to include @product_sfw
        expect(results).to include @product_nsfw
      end
    end

    describe "on indexed products with staff_picked_at" do
      let!(:staff_picked_product_one) { create(:product, :recommendable) }
      let!(:non_staff_picked_product) { create(:product, :recommendable) }
      let!(:staff_picked_product_two) { create(:product, :recommendable) }

      before do
        staff_picked_product_one.create_staff_picked_product!(updated_at: 1.hour.ago)
        staff_picked_product_two.create_staff_picked_product!(updated_at: 2.hour.ago)
        index_model_records(Link)
      end

      it "includes all products when staff_picked is not set" do
        search_options = Link.search_options({})
        results = Link.search(search_options).records
        expect(results).to include staff_picked_product_one
        expect(results).to include staff_picked_product_two
        expect(results).to include non_staff_picked_product
      end

      context "with staff_picked filter" do
        it "includes only staff_picked products, sorted" do
          search_options = Link.search_options({ staff_picked: true, sort: ProductSortKey::STAFF_PICKED })
          records = Link.search(search_options).records
          assert_equal(
            [staff_picked_product_one.id, staff_picked_product_two.id],
            records.map(&:id)
          )
        end
      end
    end

    describe "option 'from'" do
      it "is clamped from 0 to a valid max result window" do
        expect do
          Link.search(Link.search_options(from: -1)).response
        end.not_to raise_error
        expect do
          Link.search(Link.search_options(from: 999_999_999)).response
        end.not_to raise_error
      end
    end

    describe "searching by multiple user IDs" do
      let!(:product1) { create(:product) }
      let!(:product2) { create(:product) }

      before do
        index_model_records(Link)
      end

      it "returns products from both users" do
        expect(Link.search(Link.search_options(user_id: [product1.user_id, product2.user_id])).records.map(&:id)).to eq([product1.id, product2.id])
      end
    end
  end
end
