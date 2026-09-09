# frozen_string_literal: true

class ProductOfferCodeIndexingService
  # Transient transport statuses and unclassified/seller-wide failures keep the
  # seller scan pinned for Sidekiq retry. Only known permanent document-level
  # rejections are reported and skipped so the cursor can advance.
  # 429 arrives as a generic ServerError in elasticsearch-transport 7.x.
  RETRYABLE_STATUS_CODES = [408, 409, 429, 500, 502, 503, 504].freeze
  # Bare parsing_exception is also used for malformed requests / batch-wide
  # failures; only document-specific subtypes may be skipped.
  DOCUMENT_LEVEL_400_MARKERS = %w[
    mapper_parsing_exception
    document_parsing_exception
  ].freeze

  def initialize(products)
    @products = products
  end

  def perform
    return if @products.empty?

    raise Elasticsearch::Transport::Transport::Errors::NotFound, "index_not_found_exception" unless Link.__elasticsearch__.client.indices.exists?(index: Link.index_name)

    product_ids = @products.map(&:id)
    universal_codes = OfferCode.alive.universal.where(user_id: @products.map(&:user_id).uniq).to_a.group_by(&:user_id)
    product_codes = OfferCode.alive.joins(:products).where(links: { id: product_ids })
                            .pluck("links.id", "offer_codes.id", "offer_codes.code", "offer_codes.created_at").group_by(&:first)
    exclusions = OfferCode.joins(:excluded_products).where(links: { id: product_ids })
                          .pluck("links.id", "offer_codes.id").group_by(&:first)

    @products.each do |product|
      excluded_ids = exclusions.fetch(product.id, []).map(&:last)
      codes = product_codes.fetch(product.id, []).map { |_, id, code, created_at| [id, code, created_at] }
      universal_codes.fetch(product.user_id, []).each do |code|
        next if code.currency_type.present? && code.currency_type != product.price_currency_type
        next if excluded_ids.include?(code.id)

        codes << [code.id, code.code, code.created_at]
      end
      values = codes.sort_by(&:last).last(Link::MAX_OFFER_CODES_IN_INDEX).map { _1[1] }
      yield if block_given?
      index_offer_codes(product, values) { yield if block_given? }
    end
  end

  private
    def index_offer_codes(product, values)
      product.__elasticsearch__.update_document_attributes("offer_codes" => values)
    rescue Elasticsearch::Transport::Transport::Errors::NotFound => error
      raise unless error.message.include?("document_missing_exception")

      yield if block_given?
      begin
        product.__elasticsearch__.index_document unless product.deleted?
      rescue => error
        report_indexing_failure(product, error)
      end
    rescue => error
      report_indexing_failure(product, error)
    end

    def report_indexing_failure(product, error)
      raise if error.is_a?(Elasticsearch::Transport::Transport::Errors::NotFound) && error.message.include?("index_not_found")
      raise if retryable_indexing_error?(error)

      ErrorNotifier.notify(error, product_id: product.id, user_id: product.user_id)
      # Skip only known document-level 400s. Index-wide 400s (e.g. index_closed)
      # must preserve pending work.
      raise unless permanent_document_indexing_error?(error)
    end

    def permanent_document_indexing_error?(error)
      return false unless elasticsearch_status_code(error) == 400

      message = error.message.to_s
      DOCUMENT_LEVEL_400_MARKERS.any? { message.include?(_1) }
    end

    def retryable_indexing_error?(error)
      return true if error.is_a?(Faraday::TimeoutError) || error.is_a?(Faraday::ConnectionFailed)

      RETRYABLE_STATUS_CODES.include?(elasticsearch_status_code(error))
    end

    def elasticsearch_status_code(error)
      status = Elasticsearch::Transport::Transport::ERRORS.key(error.class)
      if status.nil? && error.is_a?(Elasticsearch::Transport::Transport::ServerError)
        status = Integer(Regexp.last_match(1), 10) if error.message =~ /\A\[(\d{3})\]/
      end
      status
    end
end
