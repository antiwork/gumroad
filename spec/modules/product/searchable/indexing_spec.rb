# frozen_string_literal: true

require "spec_helper"

describe "Product::Searchable - Indexing scenarios" do
  before do
    @product = create(:product_with_files)
  end

  describe "#as_indexed_json" do
    it "includes all properties" do
      taxonomy = create(:taxonomy)
      @product.update!(name: "Searching for Robby Fischer", description: "Search search search", taxonomy:, is_adult: true)
      @product.tag!("tag")
      @product.save_files!([{ external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/some-url.txt" }])
      @product.save_files!([
                             { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png" },
                             { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pic.jpg" },
                             { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/other.jpg" },
                           ])
      @product.user.update!(name: "creator name", user_risk_state: "compliant")
      purchase = create(:purchase_with_balance, link: @product, seller: @product.user, price_cents: @product.price_cents)
      review = create(:product_review, purchase:)
      create(:purchase_with_balance, link: @product, seller: @product.user, price_cents: @product.price_cents, created_at: 6.months.ago)
      index_model_records(Purchase)

      properties = @product.as_indexed_json

      # Values for all search properties must be returned by this method
      expect(properties.keys).to match_array(Product::Searchable::SEARCH_FIELDS.map(&:as_json))
      expect(properties["name"]).to eq("Searching for Robby Fischer")
      expect(properties["description"]).to eq("Search search search")
      expect(properties["tags"]).to eq(["tag"])
      expect(properties["creator_name"]).to eq("creator name")
      expect(properties["sales_volume"]).to eq(100)
      expect(properties["is_recommendable"]).to eq(true)
      expect(properties["rated_as_adult"]).to eq(true)
      expect(properties["average_rating"]).to eq(review.rating)
      expect(properties["reviews_count"]).to eq(1)
      expect(properties["is_physical"]).to eq(false)
      expect(properties["is_subscription"]).to eq(false)
      expect(properties["is_preorder"]).to eq(false)
      expect(properties["filetypes"]).to match_array(["png", "jpg"])
      expect(properties["is_alive_on_profile"]).to eq(true)
      expect(properties["is_call"]).to eq(false)
      expect(properties["is_alive"]).to eq(true)
      expect(properties["creator_external_id"]).to eq(@product.user.external_id)
      expect(properties["content_updated_at"]).to eq(@product.content_updated_at.iso8601)
      expect(properties["taxonomy_id"]).to eq(taxonomy.id)
      expect(properties["total_fee_cents"]).to eq(93)
      expect(properties["past_year_fee_cents"]).to eq(186)
    end
  end

  describe "#build_search_update" do
    it "returns the attributes to update in Elasticsearch" do
      product_name = "Some new name"
      @product.update!(name: product_name)

      update_properties = @product.build_search_update(%w[name])

      expect(update_properties.keys).to match_array(%w[name])
      expect(update_properties["name"]).to eq(product_name)
    end
  end

  describe "#enqueue_search_index!" do
    it "indexes product via ProductIndexingService" do
      expect(ProductIndexingService).to receive(:perform).with(product: @product, action: "index", on_failure: :async).and_call_original
      @product.enqueue_search_index!
    end
  end

  describe "#enqueue_index_update_for" do
    it "updates product document via ProductIndexingService" do
      expect(ProductIndexingService).to receive(:perform).with(product: @product, action: "update", attributes_to_update: %w[name filetypes], on_failure: :async).and_call_original
      @product.enqueue_index_update_for(%w[name filetypes])
    end
  end

  describe "Indexing the changes through callbacks" do
    it "imports all search fields when a product is created" do
      product = build(:product)
      expect(ProductIndexingService).to receive(:perform).with(product:, action: "index", on_failure: :async).and_call_original
      product.save!
    end

    it "correctly indexes price_cents", :elasticsearch_wait_for_refresh do
      document = EsClient.get(index: Link.index_name, id: @product.id)
      expect(document["_source"]["price_cents"]).to eq(100)
    end

    describe "on product update" do
      it "requests update of the name & rated_as_adult fields on name change" do
        expect_product_update %w[name rated_as_adult]

        @product.update!(name: "I have a great idea for a name.")
      end

      it "requests update of the description & rated_as_adult fields on description change" do
        expect_product_update %w[description rated_as_adult]

        @product.update!(description: "I have a great idea for a description.")
      end

      it "sends updated rated_as_adult field on `is_adult` change" do
        expect_product_update %w[rated_as_adult]

        is_adult = !@product.is_adult
        @product.update!(is_adult:)
      end

      it "sends updated is_recommendable & display_product_reviews fields on `display_product_reviews` change" do
        expect_product_update %w[display_product_reviews is_recommendable]

        @product.display_product_reviews = !@product.display_product_reviews?
        @product.save!
      end

      it "sends updated is_recommendable and is_alive_on_profile and is_alive fields on `purchase_disabled_at` change" do
        expect_product_update %w[is_recommendable is_alive_on_profile is_alive]

        @product.purchase_disabled_at = Time.current
        @product.save!
      end

      it "sends updated is_recommendable and is_alive_on_profile and is_alive fields on `banned_at` change" do
        expect_product_update %w[is_recommendable is_alive_on_profile is_alive]

        @product.update!(banned_at: Time.current)
      end

      it "sends updated is_recommendable and is_alive_on_profile and is_alive fields on `deleted_at` change" do
        expect_product_update %w[is_recommendable is_alive_on_profile is_alive]

        @product.update!(deleted_at: Time.current)
      end

      it "sends updated taxonomy_id field on `taxonomy_id` change" do
        expect_product_update %w[taxonomy_id is_recommendable]

        @product.update!(taxonomy: create(:taxonomy))
      end

      it "sends updated is_recommendable & is_alive_on_profile field on `archived` change" do
        expect_product_update %w[is_recommendable is_alive_on_profile]

        @product.update!(archived: true)
      end

      it "sends updated price_cents & available_price_cents fields on price_range change" do
        expect_product_update %w[price_cents available_price_cents]

        new_price = @product.price_cents + 100
        @product.update!(price_range: new_price)
      end

      it "sends updated price_cents & available_price_cents fields on price_cents change" do
        expect_product_update %w[price_cents available_price_cents]

        new_price = @product.price_cents + 100
        @product.update!(price_cents: new_price)
      end

      it "sends updated is_preorder on preorder state change" do
        expect_product_update %w[is_preorder]

        @product.is_in_preorder_state = !@product.is_in_preorder_state
        @product.save!
      end

      it "sends updated is_recommendable field on max_purchase_count change" do
        expect_product_update %w[is_recommendable]

        @product.update!(max_purchase_count: 100)
      end

      it "sends updated is_call field when native_type changes to call" do
        expect_product_update %w[is_call]

        @product.native_type = Link::NATIVE_TYPE_CALL
        @product.save(validate: false)
      end

      it "does not index changes when transaction is rolled back" do
        expect(ProductIndexingService).not_to receive(:perform)

        ActiveRecord::Base.transaction do
          @product.update!(name: "new name", price_cents: 234)
          raise ActiveRecord::Rollback
        end

        document = EsClient.get(index: Link.index_name, id: @product.id)
        expect(document["_source"]["name"]).to eq("The Works of Edgar Gumstein")
        expect(document["_source"]["price_cents"]).to eq(100)
      end
    end

    it "updates review search properties on review save" do
      expect_product_update %w[average_rating reviews_count is_recommendable]

      purchase = create(:purchase, link: @product)
      create(:product_review, purchase:)
    end

    it "updates the index for the associated product on product file save" do
      expect_product_update %w[filetypes]

      file_params = [{ external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png" },
                     { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf" }]
      @product.save_files!(file_params)
    end

    describe "on user update" do
      it "sends updated rated_as_adult & creator_name on name change" do
        expect_product_update %w[rated_as_adult creator_name]
        user = @product.user
        user.update!(name: "New user name")
      end

      it "sends updated rated_as_adult & creator_name on username change" do
        expect_product_update %w[rated_as_adult creator_name]
        @product.user.update!(username: "newusername")
      end

      it "sends updated rated_as_adult field on bio change" do
        expect_product_update %w[rated_as_adult]
        user = @product.user
        user.update!(bio: "New user bio")
      end

      it "sends updated rated_as_adult field on all_adult_products change" do
        expect_product_update %w[rated_as_adult]
        user = @product.user
        user.update!(all_adult_products: true)
      end

      it "sends updated is_recommendable flag on payment_address update" do
        expect_product_update %w[is_recommendable]

        user = @product.user
        user.update!(payment_address: nil)
      end

      it "sends updated is_recommendable flag on creation of active bank_account" do
        expect_product_update %w[is_recommendable]
        create(:canadian_bank_account, deleted_at: 1.day.ago, user: @product.user)
        expect_product_update %w[is_recommendable]
        create(:canadian_bank_account, user: @product.user)
      end

      it "does not index products if user already has an active bank_account" do
        create(:canadian_bank_account, user: @product.user)
        expect(ProductIndexingService).not_to receive(:perform)
        create(:canadian_bank_account, user: @product.user)
      end

      it "sends updated is_recommendable field when user is marked compliant" do
        expect_product_update %w[is_recommendable]
        @product.user.mark_compliant!(author_id: create(:user).id)
      end

      it "sends updated is_recommendable field when compliant user is suspended for fraud" do
        admin = create(:user)
        @product.user.mark_compliant!(author_id: admin.id)

        expect_product_update %w[is_recommendable]
        @product.user.update!(user_risk_state: "suspended_for_fraud")
      end

      it "does nothing if no watched attributes change" do
        expect(ProductIndexingService).not_to receive(:perform)
        @product.user.update!(kindle_email: "someone@kindle.com")
      end
    end

    it "sends updated tags when a tag is created" do
      expect_product_update %w[tags]
      @product.tag!("new tag")
    end

    it "sends updated filetypes when a file is added" do
      expect_product_update %w[filetypes]
      @product.save_files!([{ external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pic.jpg" }])
    end

    it "enqueues the job when a purchase transitions to the successful state" do
      expect_product_update %w[is_recommendable]
      create(:purchase_with_balance, link: @product, seller: @product.user, price_cents: @product.price_cents)
      expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(@product.id, "update", ["sales_volume", "total_fee_cents", "past_year_fee_cents"])
    end

    it "enqueues the job when a purchase transitions to the preorder_authorization_successful state" do
      expect_product_update %w[is_recommendable]
      purchase = create(:purchase_in_progress, link: @product, seller: @product.user, is_preorder_authorization: true)
      purchase.mark_preorder_authorization_successful
      expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(@product.id, "update", ["sales_volume", "total_fee_cents", "past_year_fee_cents"])
    end
  end

  def expect_product_update(attributes)
    expect(ProductIndexingService).to receive(:perform).with(
      product: @product,
      action: "update",
      attributes_to_update: attributes,
      on_failure: :async
    ).and_call_original
  end
end
