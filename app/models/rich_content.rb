# frozen_string_literal: true

class RichContent < ApplicationRecord
  include Deletable, ExternalId, Versionable

  has_paper_trail

  FILE_EMBED_NODE_TYPE = "fileEmbed"
  FILE_EMBED_GROUP_NODE_TYPE = "fileEmbedGroup"
  ORDERED_LIST_NODE_TYPE = "orderedList"
  BULLET_LIST_NODE_TYPE = "bulletList"
  LIST_ITEM_NODE_TYPE = "listItem"
  BLOCKQUOTE_NODE_TYPE = "blockquote"
  LICENSE_KEY_NODE_TYPE = "licenseKey"
  POSTS_NODE_TYPE = "posts"
  SHORT_ANSWER_NODE_TYPE = "shortAnswer"
  LONG_ANSWER_NODE_TYPE = "longAnswer"
  FILE_UPLOAD_NODE_TYPE = "fileUpload"
  MORE_LIKE_THIS_NODE_TYPE = "moreLikeThis"
  REVIEW_CARD_NODE_TYPE = "reviewCard"
  UPSELL_CARD_NODE_TYPE = "upsellCard"
  CUSTOM_FIELD_NODE_TYPES = [SHORT_ANSWER_NODE_TYPE, LONG_ANSWER_NODE_TYPE, FILE_UPLOAD_NODE_TYPE].freeze
  COMMON_CONTAINER_NODE_TYPES = [ORDERED_LIST_NODE_TYPE, BULLET_LIST_NODE_TYPE, LIST_ITEM_NODE_TYPE, BLOCKQUOTE_NODE_TYPE].freeze
  FILE_EMBED_CONTAINER_NODE_TYPES = [FILE_EMBED_GROUP_NODE_TYPE, *COMMON_CONTAINER_NODE_TYPES].freeze

  # Nodes that occupy space in the editor but do not, by themselves, mean the
  # buyer receives anything. Each one is a single click to insert and costs the
  # seller no work, so their presence proves nothing about what was written or
  # attached. Two reasons a node lands here:
  #
  # It renders content fetched from elsewhere, and that elsewhere can be empty —
  # in which case the buyer opens the page and sees nothing at all:
  #
  #   - `posts` renders the product's published posts, and renders nothing when
  #     the seller has published none,
  #   - `fileEmbed` / `fileEmbedGroup` render an uploaded file, and render
  #     nothing once that file is deleted or was never finished uploading,
  #   - `reviewCard` renders one of the product's reviews, and renders nothing
  #     when that review can't be fetched.
  #
  # Or it points at something other than this listing's deliverable, so it can't
  # stand in for one no matter how well it renders:
  #
  #   - `moreLikeThis` renders other listings Gumroad recommends,
  #   - `upsellCard` advertises another product the buyer could also buy,
  #   - the custom-field nodes (`shortAnswer`, `longAnswer`, `fileUpload`) are
  #     form inputs that ask the BUYER for something rather than giving them
  #     anything.
  #
  # Callers that need "did the seller put something here themselves" (rather than
  # "does the editor show a block here") pass this to `has_body_content?`.
  NODE_TYPES_WITHOUT_OWN_CONTENT = [
    POSTS_NODE_TYPE,
    FILE_EMBED_NODE_TYPE,
    FILE_EMBED_GROUP_NODE_TYPE,
    REVIEW_CARD_NODE_TYPE,
    MORE_LIKE_THIS_NODE_TYPE,
    UPSELL_CARD_NODE_TYPE,
    *CUSTOM_FIELD_NODE_TYPES
  ].freeze

  DESCRIPTION_JSON_SCHEMA = {
    type: "array",
    items: { "$ref": "#/$defs/content" },

    "$defs": {
      content: {
        type: "object",
        properties: {
          type: { type: "string" },
          attrs: { type: "object", additionalProperties: true },
          content: { type: "array", items: { "$ref": "#/$defs/content" } },
          marks: {
            type: "array",
            items: {
              type: "object",
              properties: {
                type: { type: "string" },
                attrs: { type: "object", additionalProperties: true }
              },
              required: ["type"],
              additionalProperties: true
            }
          },
          text: { type: "string" }
        },
        additionalProperties: true
      }
    }
  }

  # Link and button hrefs may use any URL scheme — custom app schemes like `myapp://activate` are
  # supported on purpose so sellers can deep-link buyers into their own app — except the ones below,
  # which either execute script or read local resources in the buyer's browser. Content pages render
  # on Gumroad-owned domains, so a seller must never be able to store one of these. The editor blocks
  # them client-side too (validateUrl in app/javascript/components/RichTextEditor.tsx); this is the
  # backstop for anything writing rich content through the API.
  BLOCKED_HREF_SCHEMES = %w[javascript data vbscript file blob].freeze
  LINK_NODE_TYPES = ["link", "tiptap-link", "button"].freeze
  # Not every node keeps its click-through URL under `attrs.href`. An image stores it in
  # `attrs.link` and a media embed in `attrs.url`, and both renderers turn that value straight into
  # an anchor's `href` on the content page, so all of them need the same scheme check. Keep this map
  # in sync whenever a node type starts rendering a seller-supplied URL as a link.
  URL_ATTRS_BY_NODE_TYPE = {
    "link" => "href",
    "tiptap-link" => "href",
    "button" => "href",
    "image" => "link",
    "mediaEmbed" => "url",
  }.freeze

  belongs_to :entity, polymorphic: true, optional: true

  validates :entity, presence: true
  validates :description, json: { schema: DESCRIPTION_JSON_SCHEMA, message: :invalid }
  # Runs BEFORE the validation below so a page carrying only dead cross-product
  # embeds saves cleanly instead of failing forever — see the method for why.
  before_validation :drop_dead_cross_product_file_embeds, if: :will_save_change_to_description?
  validate :embedded_files_belong_to_product, if: :will_save_change_to_description?
  validate :link_hrefs_use_permitted_schemes, if: :will_save_change_to_description?

  def embedded_product_file_ids_in_order
    description.flat_map { select_file_embed_ids(_1) }.compact.uniq
  end

  # True when the page carries anything a buyer could actually see. A page whose
  # description is only empty structural nodes (e.g. a single bare paragraph —
  # the shape the editor creates as a blank placeholder) has no content, unless
  # the seller gave the page a title: a titled page renders its title in the
  # page list, so it is seller-authored work even with an empty body. This
  # matters for content resolution: an empty product-level placeholder page must
  # not make the product look like it has product-level content, which would
  # hide the real variant-level content from buyers.
  def has_editor_content?
    return true if title.present?

    has_body_content?
  end

  # Whether the page body itself renders something for the buyer. Unlike
  # `has_editor_content?` this ignores the page title: a titled but otherwise
  # empty page shows up in the buyer's page list, which is enough to say the
  # seller did some work, but it is not something the buyer can read.
  #
  # `excluding_node_types:` drops node types from the walk entirely, for callers
  # that need a stricter answer than "the editor shows something here". See
  # NODE_TYPES_WITHOUT_OWN_CONTENT for the set the moderation code passes and
  # why.
  def has_body_content?(excluding_node_types: [])
    description.present? && description.any? { node_has_content?(_1, excluding_node_types:) }
  end

  def owning_product
    entity.is_a?(Link) ? entity : entity.try(:link)
  end

  def cross_product_file_embed_ids
    embedded_ids = embedded_product_file_ids_in_order
    return [] if embedded_ids.empty?

    product = owning_product
    return [] if product.nil?

    ProductFile.where(id: embedded_ids).where.not(link_id: product.id).pluck(:id)
  end

  # Cross-product embeds split by whether the file they point at still exists.
  #
  # A soft-deleted foreign file delivers nothing: the editor renders its embed as
  # nothing at all, so there is no node for the seller to click and remove. Those
  # are dead content and get dropped on save (see #drop_dead_cross_product_file_embeds).
  # An ALIVE foreign file is the case #5416 was written to stop, and it stays a
  # hard validation failure — the seller can see that embed and may well intend to
  # deliver it, so silently deleting it would throw away their work.
  def cross_product_file_embeds_by_liveness
    foreign_ids = cross_product_file_embed_ids
    return { alive: [], dead: [] } if foreign_ids.empty?

    alive_ids = ProductFile.alive.where(id: foreign_ids).pluck(:id)
    { alive: alive_ids, dead: foreign_ids - alive_ids }
  end

  def self.reject_file_embeds(nodes, product_file_ids)
    Array(nodes).filter_map do |node|
      if node["type"] == FILE_EMBED_NODE_TYPE
        raw_id = node.dig("attrs", "id")
        decrypted_id = raw_id.present? ? ObfuscateIds.decrypt(raw_id) : nil
        next if decrypted_id.present? && product_file_ids.include?(decrypted_id)
        node
      elsif node["content"].is_a?(Array) && node["type"].in?(FILE_EMBED_CONTAINER_NODE_TYPES)
        remaining = reject_file_embeds(node["content"], product_file_ids)
        next if node["type"] == FILE_EMBED_GROUP_NODE_TYPE && remaining.empty?
        node.merge("content" => remaining)
      else
        node
      end
    end
  end

  def custom_field_nodes
    select_custom_field_nodes(description).uniq
  end

  def has_license_key?
    contains_license_key_node = ->(node) do
      node["type"] == LICENSE_KEY_NODE_TYPE || (node["type"].in?(COMMON_CONTAINER_NODE_TYPES) && node["content"].to_s.include?(LICENSE_KEY_NODE_TYPE) && node["content"].any? { |child_node| contains_license_key_node.(child_node) })
    end
    description.any? { |node| contains_license_key_node.(node) }
  end

  def has_posts?
    contains_posts_node = ->(node) do
      node["type"] == POSTS_NODE_TYPE || (node["type"].in?(COMMON_CONTAINER_NODE_TYPES) && node["content"].to_s.include?(POSTS_NODE_TYPE) && node["content"].any? { |child_node| contains_posts_node.(child_node) })
    end
    description.any? { |node| contains_posts_node.(node) }
  end

  def self.human_attribute_name(attr, _)
    attr == "description" ? "Content" : super
  end

  private
    def link_hrefs_use_permitted_schemes
      return unless description.is_a?(Array)

      offending = collect_blocked_hrefs(description)
      return if offending.empty?

      errors.add(:base, "Links cannot use these URL schemes: #{offending.uniq.join(', ')}")
    end

    # Walks the whole document (any nesting) collecting URLs whose scheme is blocked. A URL can
    # arrive two ways: as a link mark on some text (`marks: [{type: "link", attrs: {href:}}]`), or
    # as an attribute on a node that renders an anchor (see URL_ATTRS_BY_NODE_TYPE — the attribute
    # name differs per node type).
    def collect_blocked_hrefs(nodes)
      Array(nodes).flat_map do |node|
        next [] unless node.is_a?(Hash)

        hrefs = []
        url_attr = URL_ATTRS_BY_NODE_TYPE[node["type"]]
        hrefs << node.dig("attrs", url_attr) if url_attr
        Array(node["marks"]).each do |mark|
          next unless mark.is_a?(Hash) && mark["type"].in?(LINK_NODE_TYPES)
          hrefs << mark.dig("attrs", "href")
        end

        blocked = hrefs.compact.filter_map do |href|
          scheme = browser_canonicalized_scheme(href)
          scheme if scheme.in?(BLOCKED_HREF_SCHEMES)
        end

        blocked + collect_blocked_hrefs(node["content"])
      end
    end

    # Returns the scheme a BROWSER will see, not the scheme the raw string appears to have.
    #
    # Browsers do not read a URL literally. Before parsing it they discard any leading and trailing
    # C0 control characters and spaces, and they delete every tab, newline, and carriage return from
    # anywhere inside the string (this is the "URL cleanup" step in the WHATWG URL standard,
    # https://url.spec.whatwg.org/#url-parsing). So `"\u0001javascript:alert(1)"` and
    # `"java\tscript:alert(1)"` both load as plain `javascript:alert(1)` once the browser is done
    # with them, and clicking such a link runs the script.
    #
    # Ruby's `String#strip` only removes ASCII whitespace and NUL, and it never touches the middle
    # of the string, so matching a scheme against the stored value would let both of the examples
    # above through this validation and then hand them to a browser that happily executes them.
    # Doing the same cleanup here first is what makes the stored value and the loaded value agree.
    URL_CLEANUP_LEADING_TRAILING = /\A[\x00-\x20]+|[\x00-\x20]+\z/
    URL_CLEANUP_TAB_OR_NEWLINE = /[\t\n\r]/
    def browser_canonicalized_scheme(href)
      canonicalized = href.to_s
        .gsub(URL_CLEANUP_LEADING_TRAILING, "")
        .gsub(URL_CLEANUP_TAB_OR_NEWLINE, "")

      canonicalized[/\A([a-zA-Z][a-zA-Z0-9+.-]*):/, 1]&.downcase
    end

    # A cross-product embed pointing at a SOFT-DELETED file is unfixable from the
    # seller's side, so it must not block the save.
    #
    # #5416 added the validation below to stop products embedding another product's
    # files. That was right for new content, but it also applies to rows written
    # before it merged — and those rows already exist (usually from copy-pasting a
    # content page between two products before the editor resolved copied embeds).
    # When the foreign file has since been soft-deleted, the embed renders as
    # nothing in the editor, so the seller sees no node to delete and every save of
    # that product fails permanently with an error naming an obfuscated file ID.
    # One seller lost the ability to edit two products entirely this way
    # (Helper 98aed6e0).
    #
    # Dropping the node is safe precisely because the file is gone: a soft-deleted
    # ProductFile delivers nothing to buyers, so the embed was already dead
    # content. This is the same remediation Onetime::RemoveCrossProductFileEmbeds
    # performs in bulk, applied lazily when the seller next saves.
    #
    # ALIVE foreign files are deliberately NOT dropped here — the seller can see
    # that embed and may intend to deliver it, so it keeps failing validation
    # rather than having their content silently deleted.
    def drop_dead_cross_product_file_embeds
      return unless description.is_a?(Array)

      dead_ids = cross_product_file_embeds_by_liveness[:dead]
      return if dead_ids.empty?

      self.description = self.class.reject_file_embeds(description, dead_ids.to_set)
    end

    def embedded_files_belong_to_product
      return unless description.is_a?(Array)

      foreign_ids = cross_product_file_embed_ids
      return if foreign_ids.empty?

      errors.add(:base, "File embeds reference files not belonging to this product: #{cross_product_file_embed_error_details(foreign_ids)}")
    end

    # Names the product each foreign file actually belongs to, so the seller can
    # find and remove the embed. The bare obfuscated ID this used to emit was not
    # actionable: it appears nowhere in the UI, so there was no way to tell which
    # embed was at fault or where it came from.
    def cross_product_file_embed_error_details(foreign_ids)
      files = ProductFile.where(id: foreign_ids).includes(:link)

      files.map do |file|
        label = file.name_displayable.presence || ObfuscateIds.encrypt(file.id)
        owner = file.link&.name.presence
        owner.present? ? "#{label} (from \"#{owner}\")" : label
      end.join(", ")
    end

    def select_file_embed_ids(node)
      if node["type"] == FILE_EMBED_NODE_TYPE
        id = node.dig("attrs", "id")
        return id.present? ? ObfuscateIds.decrypt(id) : nil
      end

      if node["type"].in?(FILE_EMBED_CONTAINER_NODE_TYPES) && node["content"].to_s.include?(FILE_EMBED_NODE_TYPE)
        node["content"].flat_map { select_file_embed_ids(_1) }
      end
    end

    def select_custom_field_nodes(nodes)
      nodes.flat_map do |node|
        if CUSTOM_FIELD_NODE_TYPES.include?(node["type"])
          next [node]
        end

        if COMMON_CONTAINER_NODE_TYPES.include?(node["type"])
          next select_custom_field_nodes(node["content"])
        end

        []
      end
    end

    # A node counts as content when it's anything other than an empty container:
    # text, media/embed nodes (which have no "content" array), or a container
    # with at least one contentful child. A bare `{"type" => "paragraph"}` — the
    # editor's blank placeholder — is not content.
    def node_has_content?(node, excluding_node_types: [])
      return false unless node.is_a?(Hash)
      return false if node["type"].in?(excluding_node_types)
      return true if node["text"].present?

      children = node["content"]
      if children.is_a?(Array)
        children.any? { node_has_content?(_1, excluding_node_types:) }
      else
        # Leaf nodes without a content array (fileEmbed, image, licenseKey,
        # posts, horizontal rule, etc.) render something by themselves —
        # except structural placeholders like an empty paragraph/heading.
        !node["type"].in?(%w[paragraph heading])
      end
    end
end
