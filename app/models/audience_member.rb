# frozen_string_literal: true

class AudienceMember < ApplicationRecord
  VALID_FILTER_TYPES = %w[customer follower affiliate].freeze

  belongs_to :seller, class_name: "User"
  after_initialize :assign_default_details_value
  before_validation :compact_details
  before_validation :normalize_email, if: :email?
  validates :email, email_format: true, presence: true
  validate :details_json_has_valid_format
  before_save :assign_derived_columns

  def self.filter(seller_id:, params: {}, with_ids: false)
    params = params.slice(
      :type,
      :bought_product_ids, :bought_variant_ids,
      :not_bought_product_ids, :not_bought_variant_ids,
      :paid_more_than_cents, :paid_less_than_cents,
      :created_after, :created_before,
      :bought_from,
      :affiliate_product_ids
    ).compact_blank

    if params[:type]
      raise ArgumentError, "Invalid type: #{params[:type]}. Must be one of: #{VALID_FILTER_TYPES.join(', ')}" unless params[:type].in?(VALID_FILTER_TYPES)
      types_sql = where(:seller_id => seller_id, params[:type] => true).to_sql
    end

    if params[:bought_product_ids]
      products_relation = where(seller_id:)
      json_contains = "JSON_CONTAINS(details->'$.purchases[*].product_id', ?)"
      products_where_sql = ([json_contains] * params[:bought_product_ids].size).join(" OR ")
      products_relation = products_relation.where(products_where_sql, *params[:bought_product_ids])
      products_sql = products_relation.to_sql
    end

    if params[:bought_variant_ids]
      variants_relation = where(seller_id:)
      json_contains = "JSON_CONTAINS(details->'$.purchases[*].variant_ids[*]', ?)"
      variants_where_sql = ([json_contains] * params[:bought_variant_ids].size).join(" OR ")
      variants_relation = variants_relation.where(variants_where_sql, *params[:bought_variant_ids])
      variants_sql = variants_relation.to_sql
    end

    bought_products_union_variants_sql = [products_sql, variants_sql].compact.join(" UNION ").presence

    if params[:not_bought_product_ids]
      products_relation = where(seller_id:)
      json_contains = "JSON_CONTAINS(details->'$.purchases[*].product_id', ?)"
      products_where_sql = (["(#{json_contains} IS NULL OR #{json_contains} = 0)"] * params[:not_bought_product_ids].size).join(" AND ")
      products_relation = products_relation.where(products_where_sql, *(params[:not_bought_product_ids].zip(params[:not_bought_product_ids]).flatten))
      not_bought_products_sql = products_relation.to_sql
    end

    if params[:not_bought_variant_ids]
      variants_relation = where(seller_id:)
      json_contains = "JSON_CONTAINS(details->'$.purchases[*].variant_ids[*]', ?)"
      variants_where_sql = (["(#{json_contains} IS NULL OR #{json_contains} = 0)"] * params[:not_bought_variant_ids].size).join(" AND ")
      variants_relation = variants_relation.where(variants_where_sql, *(params[:not_bought_variant_ids].zip(params[:not_bought_variant_ids]).flatten))
      not_bought_variants_sql = variants_relation.to_sql
    end

    if params[:paid_more_than_cents] || params[:paid_less_than_cents]
      prices_relation = where(seller_id:)
      prices_relation = prices_relation.where("max_paid_cents > ?", params[:paid_more_than_cents]) if params[:paid_more_than_cents]
      prices_relation = prices_relation.where("min_paid_cents < ?", params[:paid_less_than_cents]) if params[:paid_less_than_cents]
      prices_sql = prices_relation.to_sql
    end

    if params[:created_after] || params[:created_before]
      created_at_relation = where(seller_id:)
      min_created_at_column, max_created_at_column = \
        case params[:type]
        when "customer" then [:min_purchase_created_at, :max_purchase_created_at]
        when "follower" then [:follower_created_at, :follower_created_at]
        when "affiliate" then [:min_affiliate_created_at, :max_affiliate_created_at]
        else [:min_created_at, :max_created_at]
        end
      created_at_relation = created_at_relation.where("#{max_created_at_column} > ?", params[:created_after]) if params[:created_after]
      created_at_relation = created_at_relation.where("#{min_created_at_column} < ?", params[:created_before]) if params[:created_before]
      created_at_sql = created_at_relation.to_sql
    end

    if params[:bought_from]
      country_relation = where(seller_id:).where("JSON_CONTAINS(details->'$.purchases[*].country', ?)", %("#{params[:bought_from]}"))
      country_sql = country_relation.to_sql
    end

    if params[:affiliate_product_ids]
      affiliates_relation = where(seller_id:)
      json_contains = "JSON_CONTAINS(details->'$.affiliates[*].product_id', ?)"
      affiliates_where_sql = ([json_contains] * params[:affiliate_product_ids].size).join(" OR ")
      affiliates_relation = affiliates_relation.where(affiliates_where_sql, *params[:affiliate_product_ids])
      affiliates_sql = affiliates_relation.to_sql
    end

    filter_purchases_when = (
      (params[:bought_product_ids] || params[:bought_variant_ids] || params[:affiliate_product_ids]) \
      && (params[:paid_more_than_cents] || params[:paid_less_than_cents] || params[:created_after] || params[:created_before] || params[:bought_from]))
    filter_purchases_when ||= (params[:paid_more_than_cents] && params[:paid_less_than_cents])
    filter_purchases_when ||= (params[:created_after] && params[:created_before])
    if filter_purchases_when || with_ids
      json_filter = where(seller_id:)
      json_table = <<~SQL.squish
        JSON_TABLE(details, '$' COLUMNS (
          NESTED PATH '$.follower' COLUMNS (
            follower_id INT PATH '$.id',
            follower_created_at DATETIME PATH '$.created_at'
          ),
          NESTED PATH '$.purchases[*]' COLUMNS (
            purchase_id INT PATH '$.id',
            purchase_product_id INT PATH '$.product_id',
            NESTED PATH '$.variant_ids[*]' COLUMNS (purchase_variant_id INT PATH '$'),
            purchase_price_cents INT PATH '$.price_cents',
            purchase_created_at DATETIME PATH '$.created_at',
            purchase_country CHAR(100) PATH '$.country'
          ),
          NESTED PATH '$.affiliates[*]' COLUMNS (
            affiliate_id INT PATH '$.id',
            affiliate_product_id INT PATH '$.product_id',
            affiliate_created_at DATETIME PATH '$.created_at'
          )
        ))
      SQL
      json_filter = json_filter.joins("INNER JOIN #{json_table} AS jt")
      json_filter = json_filter.where("jt.purchase_price_cents > ?", params[:paid_more_than_cents]) if params[:paid_more_than_cents]
      json_filter = json_filter.where("jt.purchase_price_cents < ?", params[:paid_less_than_cents]) if params[:paid_less_than_cents]
      timestamp_columns = if params[:type] == "customer"
        %w[purchase_created_at]
      elsif params[:type] == "follower"
        if params[:bought_product_ids] || params[:bought_variant_ids]
          %w[follower_created_at purchase_created_at]
        else
          %w[follower_created_at]
        end
      elsif params[:type] == "affiliate"
        %w[affiliate_created_at]
      else
        %w[purchase_created_at follower_created_at affiliate_created_at]
      end
      if params[:created_after]
        where_conditions = timestamp_columns.map { "jt.#{_1} > :date" }.join(" OR ")
        json_filter = json_filter.where(where_conditions, date: params[:created_after])
      end
      if params[:created_before]
        where_conditions = timestamp_columns.map { "jt.#{_1} < :date" }.join(" OR ")
        json_filter = json_filter.where(where_conditions, date: params[:created_before])
      end
      if params[:bought_product_ids] && params[:bought_variant_ids]
        json_filter = json_filter.where("jt.purchase_product_id IN (?) OR jt.purchase_variant_id IN (?)", params[:bought_product_ids], params[:bought_variant_ids])
      else
        json_filter = json_filter.where("jt.purchase_product_id IN (?)", params[:bought_product_ids]) if params[:bought_product_ids]
        json_filter = json_filter.where("jt.purchase_variant_id IN (?)", params[:bought_variant_ids]) if params[:bought_variant_ids]
      end
      if params[:affiliate_product_ids]
        json_filter = json_filter.where("jt.affiliate_product_id IN (?)", params[:affiliate_product_ids])
      end
      json_filter = json_filter.where("jt.purchase_country = ?", params[:bought_from]) if params[:bought_from]
      # Joining a JSON_TABLE yields a row for each matching element in the JSON array.
      # Our business logic says that if a user has multiple purchases or affiliates matching the filters,
      # we should only return the most recent one. This is why we use max() and group() below, when we need the ids.
      # We name those columns  (e.g. purchase_id) so the root query can access values from this subquery if necessary.
      # When we don't need the ids, we can just do a distinct (much faster) on all the rows found by the root query.
      if with_ids
        json_filter = json_filter.group(:id)
        json_filter = json_filter.select("audience_members.*, max(jt.purchase_id) AS purchase_id, jt.follower_id AS follower_id, max(jt.affiliate_id) AS affiliate_id")
        json_filter_sql = json_filter.to_sql
      elsif json_filter.where_clause.present?
        json_filter_sql = json_filter.to_sql
      end
    end

    subqueries = [
      types_sql,
      bought_products_union_variants_sql,
      not_bought_products_sql,
      not_bought_variants_sql,
      prices_sql,
      created_at_sql,
      country_sql,
      affiliates_sql,
      json_filter_sql,
    ].compact
    return where(seller_id:) if subqueries.empty?


    relation = from("(#{subqueries.first}) AS audience_members")
    subqueries[1..].each.with_index do |subquery_sql, index|
      relation = relation.joins("INNER JOIN (#{subquery_sql}) AS q#{index} ON audience_members.id = q#{index}.id")
    end

    if json_filter_sql
      json_subquery_index = subqueries[1..].index(json_filter_sql)
      # If the json filter is a subquery, we need to extract the id columns from it and add them to the root query.
      if with_ids && json_subquery_index
        relation = relation.select("audience_members.*, q#{json_subquery_index}.purchase_id AS purchase_id, q#{json_subquery_index}.follower_id AS follower_id, q#{json_subquery_index}.affiliate_id AS affiliate_id")
      elsif !with_ids
        # If we didn't get the rows with ids (that subquery includes a `group by`), they may not be unique.
        relation = relation.distinct
      end
    end

    relation
  end

  # Admin method: refreshes all audience members for a seller.
  # Very slow, only use when absolutely necessary.
  def self.refresh_all!(seller:)
    emails = Set.new
    batch_size = 10_000
    # gather all possible emails (the records will be filtered later)
    seller.sales.select(:id, :email).find_each(batch_size:) { emails << _1.email.downcase }
    seller.followers.alive.select(:id, :email).find_each(batch_size:) { emails << _1.email.downcase }
    seller.direct_affiliates.alive.includes(:affiliate_user).select(:id, :affiliate_user_id).find_each(batch_size:) { emails << _1.affiliate_user.email.downcase }
    # remove members that are no longer members
    seller.audience_members.find_each { emails.member?(_1.email) || _1.destroy! }
    # create or update members
    emails.each { seller.audience_members.find_or_initialize_by(email: _1).refresh! }
    # return final count
    seller.audience_members.count
  end

  # Admin method: refreshes the details of a specific audience member, or deletes record if no longer a member.
  def refresh!
    self.details = {}
    seller.sales.where(email:).find_each do |purchase|
      self.details["purchases"] ||= []
      self.details["purchases"] << purchase.audience_member_details if purchase.should_be_audience_member?
    end

    follower = seller.followers.find_by(email:)
    self.details["follower"] = follower.audience_member_details if follower&.should_be_audience_member?

    seller.direct_affiliates.includes(:affiliate_user).where(users: { email: }).find_each do |affiliate|
      next unless affiliate.should_be_audience_member?
      self.details["affiliates"] ||= []
      affiliate.product_affiliates.each do |product_affiliate|
        self.details["affiliates"] << affiliate.audience_member_details(product_id: product_affiliate.link_id)
      end
    end

    if valid?
      save!
    elsif persisted?
      destroy!
    end
  end

  private
    def assign_default_details_value
      return if persisted?
      self.details ||= {}
    end

    def compact_details
      self.details = self.details.compact_blank
      self.details.slice("purchases", "affiliates").each { _2.each(&:compact_blank!) }
    end

    def details_json_has_valid_format
      schema_file = Rails.root.join("lib", "json_schemas", "audience_member_details.json").to_s
      JSON::Validator.fully_validate(schema_file, details).each { errors.add(:details, _1) }
    end

    def normalize_email
      self.email = email.strip.downcase
    end

    def assign_derived_columns
      self.customer = details["purchases"].present?
      self.follower = details["follower"].present?
      self.affiliate = details["affiliates"].present?
      self.min_paid_cents, self.max_paid_cents = Array.wrap(details["purchases"]).map { _1["price_cents"] }.compact.minmax
      self.min_purchase_created_at, self.max_purchase_created_at = Array.wrap(details["purchases"]).map { _1["created_at"] }.compact.minmax
      self.follower_created_at = details.dig("follower", "created_at")
      self.min_affiliate_created_at, self.max_affiliate_created_at = Array.wrap(details["affiliates"]).map { _1["created_at"] }.compact.minmax
      self.min_created_at, self.max_created_at = [min_purchase_created_at, max_purchase_created_at, follower_created_at, min_affiliate_created_at, max_affiliate_created_at].compact.minmax
    end
end
