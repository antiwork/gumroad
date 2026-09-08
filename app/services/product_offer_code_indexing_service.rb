# frozen_string_literal: true

class ProductOfferCodeIndexingService
  # Failures that should keep the seller scan pinned so Sidekiq can retry the
  # same batch. Permanent per-product errors are reported and skipped instead.
  RETRYABLE_ERRORS = [
    Faraday::TimeoutError,
    Faraday::ConnectionFailed,
    Elasticsearch::Transport::Transport::Errors::RequestTimeout,
    Elasticsearch::Transport::Transport::Errors::Conflict,
    Elasticsearch::Transport::Transport::Errors::InternalServerError,
    Elasticsearch::Transport::Transport::Errors::BadGateway,
    Elasticsearch::Transport::Transport::Errors::ServiceUnavailable,
    Elasticsearch::Transport::Transport::Errors::GatewayTimeout
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
      begin
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
    end

    def report_indexing_failure(product, error)
      raise if error.is_a?(Elasticsearch::Transport::Transport::Errors::NotFound) && error.message.include?("index_not_found")
      raise if RETRYABLE_ERRORS.any? { error.is_a?(_1) }

      ErrorNotifier.notify(error, product_id: product.id, user_id: product.user_id)
    end
end
