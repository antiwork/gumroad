# frozen_string_literal: true

# What a buyer receives, before purchase: formats, total size and file count per option.
# Never exposes file names or URLs.
class Product::FileSummaryService
  def initialize(product)
    @product = product
  end

  # { product: summary_or_nil, options: { option_external_id => summary_or_nil } }
  def perform
    return { product: nil, options: {} } if product.is_physical? || product.is_bundle?

    shared = product.has_product_level_rich_content?
    product_summary = summarize(product) if shared
    records = product.option_records
    preload_delivered_files(records) unless shared
    options = records.index_with { |record| shared ? product_summary : summarize(record) }
    {
      product: product_summary,
      options: options.transform_keys(&:external_id).compact,
    }
  end

  private
    attr_reader :product

    # summarize reads each record's pages and files, so without this the option loop
    # issues two queries per option.
    def preload_delivered_files(records)
      ActiveRecord::Associations::Preloader.new(
        records:,
        associations: [:alive_rich_contents, :product_files],
      ).call
    end

    def summarize(provider)
      files = delivered_files(provider).reject(&:external_link?)
      return if files.empty?

      sizes = files.map(&:size)
      {
        formats: files.map { _1.filetype.to_s.upcase.presence }.compact.uniq.sort,
        total_size: sizes.any?(&:nil?) ? nil : sizes.sum,
        count: files.size,
      }
    end

    # Mirrors UrlRedirect#alive_product_files: files embedded in the pages when there are any.
    # Reads the loaded collections when the caller preloaded them.
    def delivered_files(provider)
      embedded_ids = provider.alive_rich_contents.flat_map(&:embedded_product_file_ids_in_order).uniq
      files = provider.product_files.select(&:alive?)
      embedded_ids.any? ? files.select { embedded_ids.include?(_1.id) } : files
    end
end
