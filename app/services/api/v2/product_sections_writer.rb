# frozen_string_literal: true

# Apply the whole layout in one transaction so failures leave no partial changes.
# Check `known_section_ids` under the lock before deleting sections, so a confirmed
# proposal cannot delete a section added after the seller reviewed it.
class Api::V2::ProductSectionsWriter
  Result = Struct.new(:error, :stale, keyword_init: true) do
    def success? = error.nil?
  end

  ENTRY_MESSAGE = "sections must be an array of section ids or objects."
  OWNERSHIP_MESSAGE = "One or more sections do not belong to this product."
  # seller_profile_sections.header is a varchar(255); a longer one would raise instead of failing cleanly.
  MAX_HEADER_LENGTH = 255

  CREATE_TYPES = {
    "featured_product" => SellerProfileFeaturedProductSection,
    "products" => SellerProfileProductsSection,
  }.freeze

  # The contents a section of each type accepts. `header` is a plain column, allowed on every type.
  CONTENT_KEYS = {
    "SellerProfileFeaturedProductSection" => %w[featured_product],
    "SellerProfileProductsSection" => %w[shown_products default_product_sort show_filters add_new_products],
  }.freeze
  EDITABLE_KEYS = CONTENT_KEYS.values.flatten.freeze
  ENTRY_KEYS = (EDITABLE_KEYS + %w[id type header]).freeze
  # The schema is the single source of truth for the sort orders the dashboard offers.
  SORT_TYPES = SellerProfileProductsSection.json_schema.dig("properties", "default_product_sort", "enum").freeze
  # Defaults for a created products section, mirroring the dashboard's "add section": a section that
  # lists nothing reads as "No products found", so a new one starts with the seller's whole catalog.
  NEW_PRODUCTS_SECTION_DEFAULTS = { "default_product_sort" => "page_layout", "show_filters" => false, "add_new_products" => true }.freeze

  def initialize(product)
    @product = product
    @seller = product.user
  end

  # `sections` is the complete ordered layout. `options` may carry `main_section_index` and
  # `known_section_ids` (the ids the caller read before preparing this write).
  def write!(sections:, **options)
    return failure(ENTRY_MESSAGE) unless sections.is_a?(Array)

    entries = []
    sections.each do |entry|
      entry = { "id" => entry } if entry.is_a?(String)
      attributes = entry.is_a?(ActionController::Parameters) ? entry.to_unsafe_h : entry
      return failure(ENTRY_MESSAGE) unless attributes.is_a?(Hash)

      built, error = parse_entry(attributes)
      return failure(error) if error

      entries << built
    end

    section_ids = entries.filter_map { _1[:id] }
    return failure("sections must not list the same section twice.") if section_ids.uniq.length != section_ids.length

    known_ids, error = parse_known_ids(options)
    return failure(error) if error

    main_section_index, error = parse_main_section_index(options, entries.length)
    return failure(error) if error

    error = nil
    stale = false
    # Seller row, product row, then the profile row: the order `Link#lock_for_permalink_claim!` and the
    # editor's save take them, so the two cannot deadlock. The profile lock serializes this with the
    # other section json_data writers.
    with_seller_then_product_lock do
      @seller.with_profile_sections_lock do
        # The ownership and staleness checks run under the product lock so a concurrent writer cannot
        # add, remove or steal a section between the check and the destroy below. The dashboard's
        # section editor can still add or delete a section row without it: one added after this
        # snapshot is invisible to the destroy too, so it survives; one this write changes that was
        # deleted is caught below.
        current_ids = @product.seller_profile_sections.pluck(:id)
        if (section_ids - current_ids).any?
          error = OWNERSHIP_MESSAGE
          raise ActiveRecord::Rollback
        end
        if known_ids && (current_ids - section_ids - known_ids).any?
          error = "A section was added after this change was prepared. Read the product again and prepare a fresh sections list."
          stale = true
          raise ActiveRecord::Rollback
        end

        # A locking read, before anything is written: the profile lock's own lookup fixed this
        # transaction's snapshot before it waited, so a plain read could miss a `shown_products` change
        # the previous holder committed, or a section it deleted.
        changed_ids = entries.filter_map { _1[:id] unless _1[:id].nil? || _1[:attributes].empty? }
        changed = @product.seller_profile_sections.lock.where(id: changed_ids).index_by(&:id)
        if changed.size != changed_ids.size
          error = OWNERSHIP_MESSAGE
          raise ActiveRecord::Rollback
        end

        # Created in place, so the saved order is the order the seller confirmed. The type has to be
        # explicit: the base class defaults to a products section (the column default).
        ordered_ids = entries.map do |entry|
          next entry[:id] if entry[:id]

          @product.seller_profile_sections.create!(entry[:attributes].merge(seller: @seller, type: entry[:type])).id
        end

        entries.each do |entry|
          next if entry[:id].nil? || entry[:attributes].empty?

          section = changed.fetch(entry[:id])
          attributes = entry[:attributes].dup
          # The schema only allows an integer when the key exists, so clearing removes the key.
          section.json_data = section.json_data.except("featured_product_id") if attributes.key?(:featured_product_id) && attributes[:featured_product_id].nil?
          section.update!(attributes.except(*([:featured_product_id] if attributes[:featured_product_id].nil?)))
        end

        @product.sections = ordered_ids
        @product.main_section_index = main_section_index if main_section_index
        @product.save!
        @product.seller_profile_sections.where.not(id: ordered_ids).destroy_all
      end
    end
    return Result.new(error:, stale:) if error

    Result.new
  rescue ActiveRecord::RecordInvalid => e
    failure(e.record.errors.full_messages.to_sentence.presence || "The sections could not be saved.")
  end

  private
    def with_seller_then_product_lock(&block)
      User.transaction do
        User.where(id: @seller.id).lock.pick(:id)
        @product.with_lock(&block)
      end
    end

    def failure(error)
      Result.new(error:)
    end

    # A string entry (or an object with just an id) keeps an existing section exactly as it is.
    def parse_entry(attributes)
      attributes = attributes.transform_keys(&:to_s)
      if (unknown = attributes.keys - ENTRY_KEYS).any?
        return [nil, "#{unknown.first} is not a section field. Allowed: #{ENTRY_KEYS.join(", ")}."]
      end

      return [nil, "header must be a string."] if attributes.key?("header") && !attributes["header"].is_a?(String)
      return [nil, "header must be at most #{MAX_HEADER_LENGTH} characters."] if attributes.key?("header") && attributes["header"].length > MAX_HEADER_LENGTH

      id = attributes["id"]
      type = attributes["type"]
      if id.present? && type.present?
        return [nil, "A section entry takes either id (an existing section) or type (a new one), not both."]
      end
      return [nil, "Each object in sections must have an id or a type."] if id.blank? && type.blank?

      id.present? ? parse_existing_entry(id, attributes) : parse_new_entry(type, attributes)
    end

    def parse_existing_entry(external_id, attributes)
      return [nil, ENTRY_MESSAGE] unless external_id.is_a?(String)

      id = ObfuscateIds.decrypt(external_id)
      return [nil, "One or more sections were not found."] if id.nil?

      section = SellerProfileSection.find_by(id:)
      return [nil, OWNERSHIP_MESSAGE] if section.nil? || section.product_id != @product.id

      contents = attributes.except("id", "type", "header")
      allowed = CONTENT_KEYS[section.type.to_s]
      if allowed.nil?
        return [nil, "Only featured product and products sections can have their contents changed here."] if contents.any?
        return [{ id:, attributes: header_attributes(attributes) }, nil]
      end
      if (unexpected = contents.keys - allowed).any?
        return [nil, "#{unexpected.first} is not a field of a #{section.type.delete_prefix("SellerProfile").delete_suffix("Section").underscore.humanize.downcase} section."]
      end

      attrs, error = content_attributes(allowed, attributes, section:)
      return [nil, error] if error

      [{ id:, attributes: header_attributes(attributes).merge(attrs) }, nil]
    end

    def parse_new_entry(type, attributes)
      klass = CREATE_TYPES[type]
      return [nil, "type must be one of: #{CREATE_TYPES.keys.join(", ")}."] if klass.nil?

      allowed = CONTENT_KEYS.fetch(klass.name.to_s)
      attrs, error = content_attributes(allowed, attributes, creating: true)
      return [nil, error] if error
      return [nil, "A featured product section needs a featured_product."] if klass == SellerProfileFeaturedProductSection && attrs[:featured_product_id].nil?

      [{ id: nil, type: klass.name, attributes: header_attributes(attributes, blank_default: true).merge(attrs) }, nil]
    end

    # The header is the single source of truth for whether the section shows its name (a blank header
    # hides it), so `hide_header` stays derived rather than exposed as its own field. An entry that
    # does not mention the header leaves it exactly as it is.
    def header_attributes(attributes, blank_default: false)
      return { header: "", hide_header: true } if blank_default && !attributes.key?("header")
      return {} unless attributes.key?("header")

      header = attributes["header"]
      { header:, hide_header: header.blank? }
    end

    # Translates the contents an entry carries into section attributes. `allowed` is what the
    # section's type accepts, so a model that sends a products field to a featured section is told
    # rather than silently ignored (the v2 API drops unknown body keys). `section` is the existing
    # section being changed: products it already lists stay allowed even if no longer live (new
    # products join `add_new_products` sections as drafts), so re-sending its own list never fails.
    def content_attributes(allowed, attributes, creating: false, section: nil)
      attrs = {}

      if attributes.key?("featured_product")
        return [nil, "featured_product is not a field of this section."] unless allowed.include?("featured_product")
        id, error = resolve_featured_product(attributes["featured_product"], current: section.try(:featured_product_id))
        return [nil, error] if error
        attrs[:featured_product_id] = id
      end

      if attributes.key?("shown_products")
        return [nil, "shown_products is not a field of this section."] unless allowed.include?("shown_products")
        ids, error = resolve_products(attributes["shown_products"], current: section.try(:shown_products))
        return [nil, error] if error
        attrs[:shown_products] = ids
      elsif creating && allowed.include?("shown_products")
        attrs[:shown_products] = @seller.links.alive.not_archived.pluck(:id)
      end

      if attributes.key?("default_product_sort")
        return [nil, "default_product_sort is not a field of this section."] unless allowed.include?("default_product_sort")
        value = attributes["default_product_sort"]
        return [nil, "default_product_sort must be one of: #{SORT_TYPES.join(", ")}."] unless SORT_TYPES.include?(value)
        attrs[:default_product_sort] = value
      elsif creating && allowed.include?("default_product_sort")
        attrs[:default_product_sort] = NEW_PRODUCTS_SECTION_DEFAULTS["default_product_sort"]
      end

      %w[show_filters add_new_products].each do |key|
        if attributes.key?(key)
          return [nil, "#{key} is not a field of this section."] unless allowed.include?(key)
          value, error = boolean_value(attributes[key], key)
          return [nil, error] if error
          attrs[key.to_sym] = value
        elsif creating && allowed.include?(key)
          attrs[key.to_sym] = NEW_PRODUCTS_SECTION_DEFAULTS[key]
        end
      end

      [attrs, nil]
    end

    # Blank clears the featured product (the dashboard's product picker clears it the same way).
    def resolve_featured_product(value, current: nil)
      return [nil, nil] if value.nil? || value == ""
      return [nil, "featured_product must be a product id."] unless value.is_a?(String)

      id = ObfuscateIds.decrypt(value)
      return [nil, "One or more products were not found."] if id.nil?
      return [nil, "The featured product must be one of your own live products."] unless id == current || @seller.links.alive.not_archived.exists?(id:)

      [id, nil]
    end

    def resolve_products(value, current: nil)
      return [nil, "shown_products must be an array of product ids."] unless value.is_a?(Array) && value.all? { |id| id.is_a?(String) }

      ids = value.map { ObfuscateIds.decrypt(_1) }
      return [nil, "One or more products were not found."] if ids.any?(&:nil?)
      return [nil, "shown_products must not list the same product twice."] if ids.uniq.length != ids.length
      owned = @seller.links.alive.not_archived.where(id: ids).pluck(:id)
      return [nil, "Every listed product must be one of your own live products."] unless (ids - owned - Array(current)).empty?

      [ids, nil]
    end

    def boolean_value(value, key)
      return [true, nil] if value == true || value == "true"
      return [false, nil] if value == false || value == "false"

      [nil, "#{key} must be true or false."]
    end

    def parse_known_ids(options)
      return [nil, nil] unless options.key?(:known_section_ids)

      known = options[:known_section_ids]
      ids = known.map { |id| ObfuscateIds.decrypt(id) } if known.is_a?(Array) && known.all? { |id| id.is_a?(String) }
      return [nil, "known_section_ids must be an array of section ids."] if ids.nil? || ids.any?(&:nil?)

      [ids, nil]
    end

    def parse_main_section_index(options, section_count)
      return [nil, nil] unless options.key?(:main_section_index)

      value = options[:main_section_index]
      unless (value.is_a?(Integer) || value.is_a?(String)) && value.to_s.match?(/\A\d+\z/)
        return [nil, "main_section_index must be a non-negative integer."]
      end

      [[value.to_i, section_count].min, nil]
    end
end
