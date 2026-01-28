# frozen_string_literal: true

module ProductsHelper
  include CdnUrlHelper
  include Pagy::Backend
  include CustomDomainConfig

  def files_data(product)
    product.product_files.alive.in_order.includes(:alive_subtitle_files).map(&:as_json)
  end

  def file_specific_attributes(product)
    {
      permalink: product.unique_permalink,
      audio: product.has_filegroup?("audio"),
      pdf: product.has_filetype?("pdf"),
      is_streamable: product.streamable?,
      is_listenable: product.listenable?,
      can_enable_rentals: product.can_enable_rentals?,
      purchase_type: product.purchase_type,
      is_rentable: !product.buy_only?,
    }
  end

  def i_want_this_button_override_supported?(product)
    !product.is_recurring_billing && !product.rent_only?
  end

  def view_content_button_text(product)
    product.custom_view_content_button_text.presence || "View content"
  end

  def variants_displayable(variants)
    return "" if variants.size == 1 && variants.first.name == "Untitled" # Don't show Untitled tier to customers
    sentence = ""
    names = variants.map(&:name)
    sentence = "(#{names.join(', ')})" unless variants.empty?
    sentence
  end

  def variant_names_displayable(names)
    return if names.none?
    return if names.size == 1 && names.first == "Untitled" # Don't show Untitled tier to customers
    names.join(", ")
  end

  def variants_and_quantity_displayable(variants, quantity)
    sentence = ""
    names = variants.map(&:name)
    names << "Qty: #{quantity}" if quantity > 1
    sentence = "(#{names.join(', ')})" if names.present?
    sentence
  end

  def url_for_product_page(product, request:, recommended_by: nil, recommender_model_name: nil, layout: nil, affiliate_id: nil, query: nil, offer_code: nil)
    options = {}
    options[:code] = offer_code if offer_code.present?
    if request.present? && user_by_domain(request.host) == product.user
      options.merge!(host: request.host_with_port, protocol: request.protocol)
      options[:recommended_by] = recommended_by if recommended_by.present?
      options[:recommender_model_name] = recommender_model_name if recommender_model_name.present?
      options[:layout] = layout if layout.present?
      options[:affiliate_id] = affiliate_id if affiliate_id.present?
      options[:query] = query if query.present?
      short_link_url(product.general_permalink, options)
    else
      options.merge!(recommended_by:, recommender_model_name:, layout:, affiliate_id:)
      product.long_url(**options)
    end
  end

  def create_product_page_view(user_id:, referrer:, was_product_recommended:, view_url:)
    geo = GeoIp.lookup(request.remote_ip)
    referrer = referrer.encode(Encoding.find("ASCII"), invalid: :replace, undef: :replace, replace: "")[0..190] if referrer.present?
    referrer_domain = was_product_recommended ? REFERRER_DOMAIN_FOR_GUMROAD_RECOMMENDED_PRODUCTS : Referrer.extract_domain(referrer)
    data = {
      product_id: @product.id,
      country: geo&.country_name,
      state: geo&.region_name,
      referrer_domain:,
      timestamp: Time.current.iso8601,
      seller_id: @product.user_id,
      user_id:,
      ip_address: request.remote_ip,
      url: view_url,
      browser_guid: cookies[:_gumroad_guid],
      browser_fingerprint: Digest::MD5.hexdigest([request.env["HTTP_USER_AGENT"], params[:plugins]].join(",")),
      referrer:,
    }
    job_params = {
      class_name: "ProductPageView",
      id: SecureRandom.uuid,
      body: data
    }
    ElasticsearchIndexerWorker.perform_async("index", job_params.deep_stringify_keys)
  end

  def sort_and_paginate_products(collection:, user_id:, key: nil, direction: nil, page: 1, per_page: LinksController::PER_PAGE)
    direction = direction == "desc" ? "desc" : "asc"
    page = 1 if page.to_i <= 0
    if collection.elasticsearch_key?(key)
      collection.elasticsearch_sorted_and_paginated_by(key:, direction:, page:, per_page:, user_id:)
    else
      pagination, products = pagy(collection.sorted_by(key:, direction:, user_id:).order(created_at: :desc), limit: per_page, page:)
      [PagyPresenter.new(pagination).props, products]
    end
  end
end
