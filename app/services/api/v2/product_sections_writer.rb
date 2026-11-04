# frozen_string_literal: true

# Writes a product's per-product profile sections: the ordered blocks a product page renders above
# and below the product itself. The dashboard edits them one at a time (create, then reorder), so a
# half-applied layout is only ever a reload away; the API takes the WHOLE layout in one write.
#
# Every entry of `sections`, in render order, is either the id of a section to keep exactly as it
# is, or an object: `id` keeps that section and changes its contents, `type` creates a new one. A
# section the list leaves out is destroyed, like the dashboard editor. Only featured product and
# products sections can be created or have their contents changed here — nothing else has contents a
# seller edits.
#
# The write runs under the product's row lock, and the sections it would DESTROY are re-checked there
# against `known_section_ids` (the ids the caller — normally the agent, from the same read that
# built the confirmation card — told the seller would go), so a section added in between is never
# destroyed by a change the seller never saw.
class Api::V2::ProductSectionsWriter
  Result = Struct.new(:error, :stale, keyword_init: true) do
    def success? = error.nil?
  end

  ENTRY_MESSAGE = "sections must be an array of section ids or objects."
  OWNERSHIP_MESSAGE = "One or more sections do not belong to this product."

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
    @product.with_lock do
      # The ownership and staleness checks run under the product lock so a concurrent writer cannot
      # add, remove or steal a section between the check and the destroy below.
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

      # Created in place, so the saved order is the order the seller confirmed. The type has to be
      # explicit: the base class defaults to a products section (the column default).
      ordered_ids = entries.map do |entry|
        next entry[:id] if entry[:id]

        @product.seller_profile_sections.create!(entry[:attributes].merge(seller: @seller, type: entry[:type])).id
      end

      entries.each do |entry|
        next if entry[:id].nil? || entry[:attributes].empty?

        @product.seller_profile_sections.find(entry[:id]).update!(entry[:attributes])
      end

      @product.sections = ordered_ids
      @product.main_section_index = main_section_index if main_section_index
      @product.save!
      @product.seller_profile_sections.where.not(id: ordered_ids).destroy_all
    end
    return Result.new(error:, stale:) if error

    Result.new
  rescue ActiveRecord::RecordInvalid => e
    failure(e.record.errors.full_messages.to_sentence.presence || "The sections could not be saved.")
  end

  private
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

      attrs, error = content_attributes(allowed, attributes)
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
    # rather than silently ignored (the v2 API drops unknown body keys).
    def content_attributes(allowed, attributes, creating: false)
      attrs = {}

      if attributes.key?("featured_product")
        return [nil, "featured_product is not a field of this section."] unless allowed.include?("featured_product")
        id, error = resolve_featured_product(attributes["featured_product"])
        return [nil, error] if error
        attrs[:featured_product_id] = id
      end

      if attributes.key?("shown_products")
        return [nil, "shown_products is not a field of this section."] unless allowed.include?("shown_products")
        ids, error = resolve_products(attributes["shown_products"])
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
    def resolve_featured_product(value)
      return [nil, nil] if value.nil? || value == ""
      return [nil, "featured_product must be a product id."] unless value.is_a?(String)

      id = ObfuscateIds.decrypt(value)
      return [nil, "One or more products were not found."] if id.nil?
      return [nil, "The featured product must be one of your own live products."] unless @seller.links.alive.not_archived.exists?(id:)

      [id, nil]
    end

    def resolve_products(value)
      return [nil, "shown_products must be an array of product ids."] unless value.is_a?(Array) && value.all? { |id| id.is_a?(String) }

      ids = value.map { ObfuscateIds.decrypt(_1) }
      return [nil, "One or more products were not found."] if ids.any?(&:nil?)
      return [nil, "shown_products must not list the same product twice."] if ids.uniq.length != ids.length
      owned = @seller.links.alive.not_archived.where(id: ids).pluck(:id)
      return [nil, "Every listed product must be one of your own live products."] unless (ids - owned).empty?

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
