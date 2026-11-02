# frozen_string_literal: true

module Mcp
  # Adds the link buyers click on a product's content page: a `button` node in the page's rich
  # content, the shape the editor's Insert > Button writes (an href plus the label as its text).
  #
  # A button has no surface outside the pages, unlike a file, which the download list serves on its
  # own. So this writes only to pages the buyer reads, and gives an owner that has none a page.
  class ProductContentLink
    # The editor reads a scheme only when `//` follows it, so `example.com:8080/x` is a host with a
    # port rather than the scheme `example.com`. That rule decides the https prefix below; a scheme
    # the browser would run is refused either way, so it is read with or without the slashes.
    SCHEME_WITH_AUTHORITY = %r{\A([a-z][a-z0-9+.-]*)://}i
    LEADING_SCHEME = %r{\A([a-z][a-z0-9+.-]*):}i
    NON_ASCII = /[^\x00-\x7F]/

    class InvalidUrl < StandardError; end
    class BlockedScheme < StandardError; end

    def initialize(product:, url:, label: nil)
      @product = product
      @url = url.to_s.strip
      @label = label.to_s.strip.presence
    end

    # @return [Array<Hash>] the buttons this call added, one entry per page: { page_id:, label:, url: }
    def perform
      href = normalized_href
      label = @label || href
      added = []
      # The lock serializes concurrent adds: appending to a page is read-modify-write, and a version
      # that opens with a copy reads the pages as buyers see them now rather than a sibling's button.
      ActiveRecord::Base.transaction do
        product.lock!
        owners = page_owners
        owners.map { |owner| [owner, page_seed(owner)] }.each do |owner, seed|
          added.concat(append_button(owner, seed, href, label))
        end
      end
      added
    end

    private
      attr_reader :product

      # The pages a buyer reads: a product that shares one set across its versions serves the
      # product's own pages, and each version serves its own only when it does not.
      def page_owners
        return [product] if product.has_product_level_rich_content?

        owners = product.alive_variants.to_a
        # A purchase that names no version reads the product's own pages as soon as those carry
        # content (UrlRedirect#rich_content_provider), so a button written only on the versions
        # never reaches those buyers even though the call reports success. The product joins them
        # only when its pages already hold content: a product-level page created here would take
        # the version content those buyers read today and leave them the button alone.
        owners << product if product.alive_rich_contents.any?(&:has_editor_content?)
        owners
      end

      # In the state the July 21, 2026 restore left behind (the shared-content flag on, the product
      # level blank, the real pages on a version) a buyer without a version reads the cheapest version
      # that has content (UrlRedirect#product_or_cheapest_variant_as_rich_content_provider). A version
      # with none gets a page of its own here, which puts it in that list unless it is pricier than the
      # version holding the pages: such a version would be served to buyers without one instead, so its
      # own buyers (who read its pages when they selected it) must not miss the button and the
      # versionless ones must not lose what they read. Its page therefore opens as a copy of the
      # holder's, and a pricier version gets a page of its own without moving that fallback.
      def page_seed(owner)
        return unless owner.is_a?(BaseVariant) && product.recoverable_hidden_variant_rich_content?
        return if owner.alive_rich_contents.any?(&:has_editor_content?)

        with_content = product.alive_variants.select { _1.alive_rich_contents.any?(&:has_editor_content?) }
        return if with_content.empty?

        holder = with_content.min_by { price_order(_1) }
        return unless (price_order(owner) <=> price_order(holder)) <= 0

        holder.alive_rich_contents.order(:position).map do |page|
          { title: page.title, description: page.description.deep_dup, position: page.position }
        end
      end

      # UrlRedirect orders versions by `price_difference_cents` ascending, and a version with no price
      # difference sorts first there, so it ranks cheapest here too. Comparing the values directly
      # would raise on that nil and take the whole call down with it.
      def price_order(owner)
        [owner.price_difference_cents.nil? ? 0 : 1, owner.price_difference_cents.to_i]
      end

      # Appends to the page the editor reads first, creating it when the owner has none. Once pages
      # exist the download page shows those pages instead of the file list, so a first page created
      # for an owner that delivers files has to embed them or buyers lose their download rows.
      # Mcp::ProductFileIngest#append_embeds faces the same choice for the first file it adds.
      def append_button(owner, seed, href, label)
        page = first_page(owner, seed)
        page.update!(description: page.description.to_a + [button_node(href, label)])
        [{ page_id: page.external_id, label:, url: href }]
      end

      def first_page(owner, seed)
        existing = owner.alive_rich_contents.min_by(&:position)
        return existing if existing

        if seed
          pages = seed.map { |attrs| owner.alive_rich_contents.create!(**attrs) }
          adopt_embedded_files(owner, pages)
          return pages.first
        end

        owner.alive_rich_contents.create!(description: file_embed_nodes(owner), position: 0)
      end

      # A copy carries the holder's file embeds, and UrlRedirect#alive_product_files serves only the
      # embeds the reading version's own files hold, so the files join it too or its buyers lose them.
      def adopt_embedded_files(owner, pages)
        held_ids = owner.product_files.pluck(:id)
        embedded_ids = pages.flat_map(&:embedded_product_file_ids_in_order).uniq - held_ids
        ProductFile.where(id: embedded_ids).alive.find_each { owner.product_files << _1 }
      end

      def file_embed_nodes(owner)
        owner.alive_product_files.map do |file|
          { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
        end
      end

      def button_node(href, label)
        {
          "type" => RichContent::BUTTON_NODE_TYPE,
          "attrs" => { "href" => href },
          "content" => [{ "type" => "text", "text" => label }],
        }
      end

      # The editor's validateUrl: a link with no `scheme://` gets https, and the schemes a browser
      # would run are refused before anything is stored. RichContent's own validation backstops the
      # value that reaches the database.
      def normalized_href
        raise InvalidUrl if @url.blank?
        raise BlockedScheme if @url[LEADING_SCHEME, 1]&.downcase&.in?(RichContent::BLOCKED_HREF_SCHEMES)

        candidate = @url.match?(SCHEME_WITH_AUTHORITY) ? @url : "https://#{@url}"
        raise InvalidUrl unless URI.parse(percent_encoded_non_ascii(candidate)).host.present?

        candidate
      rescue URI::InvalidURIError
        raise InvalidUrl
      end

      # `new URL` percent-encodes the non-ASCII characters of a link and accepts it, so a Notion
      # page with a Japanese path is a link the editor stores. URI.parse reads the raw bytes and
      # refuses it, which would report the creator's working link as not a link, so the same
      # characters are encoded for the parse. Only those characters are: an ASCII space is still
      # no host, so "not a link" stays refused. The href kept is the creator's own value, since a
      # browser encodes these characters itself when it follows the link.
      def percent_encoded_non_ascii(url)
        url.gsub(NON_ASCII) { |char| char.bytes.map { |byte| format("%%%02X", byte) }.join }
      end
  end
end
