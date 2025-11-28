# frozen_string_literal: true

module Product::Searchable
  extend ActiveSupport::Concern

  # we want to show 9 tags, but this is used as an array indexing which starts at 0
  MAX_NUMBER_OF_TAGS = 8
  RECOMMENDED_PRODUCTS_PER_PAGE = 9
  MAX_NUMBER_OF_FILETYPES = 8
  MAX_OFFER_CODES_IN_INDEX = 300

  ATTRIBUTE_TO_SEARCH_FIELDS_MAP = {
    "name" => ["name", "rated_as_adult"],
    "description" => ["description", "rated_as_adult"],
    "price_cents" => ["price_cents", "available_price_cents"],
    "purchase_disabled_at" => ["is_recommendable", "is_alive_on_profile", "is_alive"],
    "deleted_at" => ["is_recommendable", "is_alive_on_profile", "is_alive"],
    "banned_at" => ["is_recommendable", "is_alive_on_profile", "is_alive"],
    "max_purchase_count" => ["is_recommendable"],
    "taxonomy_id" => ["taxonomy_id", "is_recommendable"],
    "content_updated_at" => "content_updated_at",
    "archived" => ["is_recommendable", "is_alive_on_profile"],
    "is_in_preorder_state" => "is_preorder",
    "display_product_reviews" => ["display_product_reviews", "is_recommendable"],
    "is_adult" => "rated_as_adult",
    "native_type" => "is_call",
  }.freeze
  private_constant :ATTRIBUTE_TO_SEARCH_FIELDS_MAP

  SEARCH_FIELDS = Set.new(%w[
    user_id
    is_physical
    tags
    creator_name
    sales_volume
    created_at
    average_rating
    reviews_count
    is_subscription
    is_bundle
    filetypes
    price_cents
    available_price_cents
    updated_at
    creator_external_id
    content_updated_at
    total_fee_cents
    past_year_fee_cents
    staff_picked_at
    offer_codes
  ] + ATTRIBUTE_TO_SEARCH_FIELDS_MAP.values.flatten)

  MAX_PARTIAL_SEARCH_RESULTS = 5
  MAX_RESULT_WINDOW = 10_000
  DEFAULT_SALES_VOLUME_RECENTNESS = 3.months
  HOT_AND_NEW_PRODUCT_RECENTNESS = 90.days
  TOP_CREATORS_SIZE = 6

  included do
    include Elasticsearch::Model
    include AfterCommitEverywhere

    index_name "products"

    settings number_of_shards: 1, number_of_replicas: 0, analysis: {
      filter: {
        edge_ngram_filter: {
          type: "edge_ngram",
          min_gram: "2",
          max_gram: "20",
        }
      },
      analyzer: {
        edge_ngram_analyzer: {
          type: "custom",
          tokenizer: "standard",
          filter: ["lowercase", "edge_ngram_filter"]
        }
      }
    } do
      mapping dynamic: :strict do
        # https://www.elastic.co/guide/en/elasticsearch/reference/current/analysis-edgengram-tokenizer.html
        indexes :name,
                type: :text,
                fields: {
                  ngrams: { type: :text,
                            analyzer: "edge_ngram_analyzer",
                            search_analyzer: "standard" }
                }
        indexes :description, type: :text
        # https://www.elastic.co/guide/en/elasticsearch/reference/master/dynamic-field-mapping.html
        # The subfields are defined by default as a dynamic incurred field
        # We are being explicit about its definition here
        indexes :tags, type: :text do
          indexes :keyword, type: :keyword
        end
        indexes :filetypes, type: :text do
          indexes :keyword, type: :keyword
        end
        indexes :user_id, type: :long
        indexes :taxonomy_id, type: :long
        indexes :sales_volume, type: :long
        indexes :created_at, type: :date
        indexes :alive_on_profile, type: :text do # unused
          indexes :keyword, type: :keyword, ignore_above: 256
        end
        indexes :average_rating, type: :float
        indexes :categories, type: :text do # unused
          indexes :keyword, type: :keyword, ignore_above: 256
        end
        indexes :content_updated_at, type: :date
        indexes :creator_external_id, type: :text do
          indexes :keyword, type: :keyword, ignore_above: 256
        end
        indexes :creator_name, type: :text do
          indexes :keyword, type: :keyword, ignore_above: 256
        end
        indexes :display_product_reviews, type: :boolean
        indexes :is_adult, type: :boolean
        indexes :is_physical, type: :boolean
        indexes :is_preorder, type: :boolean
        indexes :is_subscription, type: :boolean
        indexes :is_bundle, type: :boolean
        indexes :is_recommendable, type: :boolean
        indexes :is_alive_on_profile, type: :boolean
        indexes :is_call, type: :boolean
        indexes :is_alive, type: :boolean
        indexes :price_cents, type: :long
        indexes :available_price_cents, type: :long
        indexes :recommendable, type: :text do # unused
          indexes :keyword, type: :keyword, ignore_above: 256
        end
        indexes :rated_as_adult, type: :boolean
        indexes :reviews_count, type: :long
        indexes :sales_count, type: :long
        indexes :updated_at, type: :date
        indexes :total_fee_cents, type: :long
        indexes :past_year_fee_cents, type: :long
        indexes :staff_picked_at, type: :date
        indexes :offer_codes, type: :text do
          indexes :code, type: :keyword, ignore_above: 256
        end
      end

      after_create :enqueue_search_index!
      before_update :update_search_index_for_changed_fields
    end
  end

  class_methods do
    def search_options(params)
      search_options = Elasticsearch::DSL::Search.search do
        size params.fetch(:size, RECOMMENDED_PRODUCTS_PER_PAGE)
        from (params[:from].to_i - 1).clamp(0, MAX_RESULT_WINDOW - size)
        _source false
        if params[:track_total_hits]
          track_total_hits params[:track_total_hits]
        end

        query do
          bool do
            if params[:query].present?
              must do
                simple_query_string do
                  query params[:query]
                  fields %i[name creator_name description tags]
                  default_operator :and
                end
              end
            end

            if params[:user_id]
              must do
                terms user_id: Array.wrap(params[:user_id]).map(&:to_i)
              end
            else
              must do
                term is_recommendable: true
              end
              unless params[:include_rated_as_adult]
                must do
                  term rated_as_adult: false
                end
              end
            end

            if !params[:is_alive_on_profile].nil?
              must do
                term is_alive_on_profile: params[:is_alive_on_profile]
              end
            end

            if params[:ids].present?
              must do
                terms "_id" => params[:ids]
              end
            elsif params[:section].is_a? SellerProfileSection
              must do
                terms "_id" => params[:section].shown_products
              end
            end

            if params[:exclude_ids].present?
              must_not do
                terms "_id" => params[:exclude_ids]
              end
            end

            if params[:taxonomy_id]
              taxonomy_ids = if params[:include_taxonomy_descendants]
                Taxonomy.find(params[:taxonomy_id]).self_and_descendants.pluck(:id)
              else
                [params[:taxonomy_id]]
              end

              must do
                terms taxonomy_id: taxonomy_ids
              end
            end

            if params[:tags]
              must do
                terms "tags.keyword" => Array.wrap(params[:tags])
              end
            end

            if params[:filetypes]
              must do
                terms "filetypes.keyword" => Array.wrap(params[:filetypes])
              end
            end

            if params[:min_price].present? || params[:max_price].present?
              filter do
                range :available_price_cents do
                  gte params[:min_price].to_f * 100 if params[:min_price].present?
                  lte params[:max_price].to_f * 100 if params[:max_price].present?
                end
              end
            end

            if params[:rating]
              filter do
                range :average_rating do
                  gte params[:rating].to_i if params[:rating].to_i > 0
                end
              end
              must do
                term display_product_reviews: "true"
              end
            end

            if params[:min_reviews_count]
              filter do
                range :reviews_count do
                  gte params[:min_reviews_count].to_i
                end
              end
            end

            if params[:sort] == ProductSortKey::HOT_AND_NEW
              filter do
                range :created_at do
                  gte HOT_AND_NEW_PRODUCT_RECENTNESS.ago
                end
              end
            end

            if params[:staff_picked]
              filter do
                exists field: "staff_picked_at"
              end
            end

            if !params[:is_subscription].nil?
              must do
                term is_subscription: params[:is_subscription]
              end
            end

            if !params[:is_bundle].nil?
              must do
                term is_bundle: params[:is_bundle]
              end
            end

            if params.key?(:is_call)
              must do
                term is_call: params[:is_call]
              end
            end

            if params.key?(:is_alive)
              must do
                term is_alive: params[:is_alive]
              end
            end

            if params[:offer_code].present?
              must do
                term "offer_codes.code" => params[:offer_code]
              end
            end
          end
        end

        sort do
          case params[:sort]
          when ProductSortKey::FEATURED, nil
            by :total_fee_cents, order: "desc"
            by :sales_volume, order: "desc"
          when ProductSortKey::BEST_SELLERS
            by :past_year_fee_cents, order: "desc"
          when ProductSortKey::CURATED
            by :_score, order: "desc"
            by :past_year_fee_cents, order: "desc"
          when ProductSortKey::HOT_AND_NEW
            by :sales_volume, order: "desc"
          when ProductSortKey::NEWEST           then by :created_at,     order: "desc"
          when ProductSortKey::AVAILABLE_PRICE_DESCENDING, ProductSortKey::PRICE_DESCENDING then by :available_price_cents,    order: "desc", mode: "min"
          when ProductSortKey::AVAILABLE_PRICE_ASCENDING, ProductSortKey::PRICE_ASCENDING  then by :available_price_cents,    order: "asc", mode: "min"
          when ProductSortKey::IS_RECOMMENDABLE_DESCENDING then by :is_recommendable,    order: "desc"
          when ProductSortKey::IS_RECOMMENDABLE_ASCENDING  then by :is_recommendable,    order: "asc"
          when ProductSortKey::REVENUE_ASCENDING   then by :sales_volume,    order: "asc"
          when ProductSortKey::REVENUE_DESCENDING  then by :sales_volume,    order: "desc"
          when ProductSortKey::MOST_REVIEWED    then by :reviews_count,  order: "desc"
          when ProductSortKey::HIGHEST_RATED
            by :average_rating, order: "desc"
            by :reviews_count, order: "desc"
          when ProductSortKey::RECENTLY_UPDATED
            by :content_updated_at, order: "desc"
          when ProductSortKey::STAFF_PICKED
            by :staff_picked_at, order: "desc"
          end

          # In the event of a tie, sort by newest. Don't sort purchases, since they're already sorted.
          by :created_at, order: "desc" unless params[:section] && params[:sort] == ProductSortKey::PAGE_LAYOUT
        end

        aggregation "tags.keyword" do
          terms do
            field "tags.keyword"
            size MAX_NUMBER_OF_TAGS
          end
        end

        if params[:include_top_creators]
          aggregation "top_creators" do
            terms do
              field "user_id"
              size TOP_CREATORS_SIZE
              order sales_volume_sum: :desc

              aggregation "sales_volume_sum" do
                sum field: "sales_volume"
              end
            end
          end
        end
      end

      search_options = search_options.to_hash
      search_options[:query][:bool][:must] << params[:search] if params[:search]

      if (params[:ids].present? || params[:section].is_a?(SellerProfileSection)) && params[:sort] == ProductSortKey::PAGE_LAYOUT
        product_ids = params[:ids] || params[:section].shown_products
        search_options[:query][:bool][:should] ||= []
        product_ids.each_with_index do |id, i|
          search_options[:query][:bool][:should] << { term: { _id: { value: id, boost: product_ids.size - i } } }
        end
      end

      if params[:curated_product_ids].present? && params[:sort] == ProductSortKey::CURATED
        search_options[:query][:bool][:should] ||= []
        params[:curated_product_ids].each_with_index do |id, i|
          search_options[:query][:bool][:should] << { term: { _id: { value: id, boost: params[:curated_product_ids].size - i } } }
        end
      end

      search_options
    end

    def filetype_options(params)
      filetype_search_options = search_options(params.except(:filetypes))
      Elasticsearch::DSL::Search.search do
        query filetype_search_options[:query]

        aggregation "filetypes.keyword" do
          terms do
            field "filetypes.keyword"
            size MAX_NUMBER_OF_FILETYPES
          end
        end
      end
    end

    def partial_search_options(params)
      Elasticsearch::DSL::Search.search do
        size MAX_PARTIAL_SEARCH_RESULTS
        query do
          bool do
            must do
              simple_query_string do
                query params[:query]
                fields %i[name name.ngrams]
                default_operator :and
              end
            end
            must do
              term is_recommendable: true
            end
            unless params[:include_rated_as_adult]
              must do
                term rated_as_adult: false
              end
            end
          end
        end

        sort do
          by :sales_volume, order: "desc"
          by :created_at, order: "desc"
        end
      end
    end
  end

  def as_indexed_json(options = {})
    options.merge(
      build_search_update(SEARCH_FIELDS)
    ).as_json
  end

  def build_search_update(attribute_names)
    attribute_names.each_with_object({}) do |attribute_name, attributes|
      Array.wrap(attribute_name).each do |attr_name|
        attributes[attr_name] = build_search_property(attr_name)
      end
    end
  end

  def enqueue_search_index!
    after_commit do
      ProductIndexingService.perform(
        product: self.class.find(id),
        action: "index",
        on_failure: :async
      )
    end
  end

  def enqueue_index_update_for(changed_search_fields)
    after_commit do
      ProductIndexingService.perform(
        product: self.class.find(id),
        action: "update",
        attributes_to_update: changed_search_fields,
        on_failure: :async
      )
    end
  end

  private
    def build_search_property(attribute_key)
      case attribute_key
      when "name"              then name
      when "description"       then description
      when "tags"              then tags.pluck(:name)
      when "creator_name"      then user.name || user.username
      when "sales_volume"      then total_usd_cents(created_after: DEFAULT_SALES_VOLUME_RECENTNESS.ago)
      when "is_recommendable"  then recommendable?
      when "rated_as_adult"    then rated_as_adult?
      when "created_at"        then created_at
      when "average_rating"    then average_rating
      when "reviews_count"     then reviews_count
      when "price_cents"       then price_cents
      when "available_price_cents" then available_price_cents
      when "is_physical"       then is_physical
      when "is_subscription"   then is_recurring_billing
      when "is_bundle"         then is_bundle
      when "is_preorder"       then is_in_preorder_state
      when "filetypes"         then product_files.alive.pluck(:filetype).uniq
      when "user_id"           then user_id
      when "taxonomy_id"       then taxonomy_id
      when "is_alive_on_profile"  then (alive? && !archived?)
      when "is_alive"            then alive?
      when "is_call"             then native_type == Link::NATIVE_TYPE_CALL
      when "display_product_reviews" then display_product_reviews?
      when "updated_at"        then updated_at
      when "creator_external_id" then user.external_id
      when "content_updated_at" then content_updated_at
      when "total_fee_cents" then total_fee_cents(created_after: DEFAULT_SALES_VOLUME_RECENTNESS.ago)
      when "past_year_fee_cents" then total_fee_cents(created_after: 1.year.ago)
      when "staff_picked_at" then staff_picked_at
      when "offer_codes" then product_and_universal_offer_codes.last(MAX_OFFER_CODES_IN_INDEX).map(&:code)
      else
        raise "Error building search properties. #{attribute_key} is not a valid property"
      end
    end

    def update_search_index_for_changed_fields
      changed_search_fields = ATTRIBUTE_TO_SEARCH_FIELDS_MAP.flat_map do |key, fields|
        send(:"#{key}_changed?") ? fields : []
      end
      return if changed_search_fields.empty?

      enqueue_index_update_for(changed_search_fields)
    end
end
