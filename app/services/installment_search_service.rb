# frozen_string_literal: true

class InstallmentSearchService
  DEFAULT_OPTIONS = {
    ### Filters
    # Values can be an ActiveRecord object, an id, or an Array of both
    seller: nil,
    ### Fulltext search
    q: nil, # String
    ### Booleans
    exclude_deleted: false,
    exclude_workflow_installments: false,
    ### Enum
    type: nil, # values can be 'draft', 'scheduled', and 'published'
    ### Native ES params
    # Most useful defaults to have when using this service in console
    from: 0,
    size: 5,
    sort: nil, # usually: [ { created_at: :desc }, { id: :desc } ],
    _source: false,
    aggs: {},
    track_total_hits: nil,
  }

  attr_accessor :body

  def initialize(options = {})
    @options = DEFAULT_OPTIONS.merge(options)
    build_body
  end

  def process
    Installment.search(@body)
  end

  def self.search(options = {})
    new(options).process
  end

  private
    def build_body
      @body = { query: { bool: { filter: [], must: [], must_not: [] } } }
      ### Filters
      # Objects and ids
      build_body_seller
      # Booleans
      build_body_exclude_workflow_installments
      build_body_exclude_deleted
      build_body_type
      # Others
      build_body_slug
      ### Fulltext search
      build_body_fulltext_search
      build_body_native_params
    end

    def build_body_seller
      return if @options[:seller].blank?
      should = Array.wrap(@options[:seller]).map do |seller|
        seller_id = seller.is_a?(User) ? seller.id : seller
        { term: { "seller_id" => seller_id } }
      end
      @body[:query][:bool][:filter] << { bool: { minimum_should_match: 1, should: } }
    end

    def build_body_exclude_workflow_installments
      return unless @options[:exclude_workflow_installments]
      @body[:query][:bool][:must_not] << { exists: { field: "workflow_id" } }
    end

    def build_body_exclude_deleted
      return unless @options[:exclude_deleted]
      @body[:query][:bool][:must_not] << { exists: { field: "deleted_at" } }
    end

    def build_body_type
      case @options[:type]
      when "published"
        @body[:query][:bool][:must] << { exists: { field: "published_at" } }
      when "scheduled"
        @body[:query][:bool][:must_not] << { exists: { field: "published_at" } }
        @body[:query][:bool][:must] << { term: { "selected_flags" => "ready_to_publish" } }
      when "draft"
        @body[:query][:bool][:must_not] << { exists: { field: "published_at" } }
        @body[:query][:bool][:must_not] << { term: { "selected_flags" => "ready_to_publish" } }
      end
    end

    def build_body_slug
      return unless @options[:slug]
      @body[:query][:bool][:filter] << { term: { "slug" => @options[:slug] } }
    end

    def build_body_fulltext_search
      return if @options[:q].blank?
      query_string = @options[:q].strip.downcase

      @body[:query][:bool][:must] << {
        bool: {
          minimum_should_match: 1,
          should: [
            {
              multi_match: {
                query: query_string,
                fields: %w[name message]
              }
            }
          ]
        }
      }
    end

    def build_body_native_params
      [
        :from,
        :size,
        :sort,
        :_source,
        :aggs,
        :track_total_hits,
      ].each do |option_name|
        next if @options[option_name].nil?
        @body[option_name] = @options[option_name]
      end
    end
end
