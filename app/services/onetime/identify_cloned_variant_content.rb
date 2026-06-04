# frozen_string_literal: true

require "csv"

module Onetime
  class IdentifyClonedVariantContent
    BATCH_SIZE = 500
    HEADERS = %w[product_id permalink seller_email variant_count files_per_variant rich_content_pages].freeze

    def self.process(start_link_id: 0, end_link_id: nil, batch_size: BATCH_SIZE, output_path: nil)
      new.process(start_link_id:, end_link_id:, batch_size:, output_path:)
    end

    def process(start_link_id: 0, end_link_id: nil, batch_size: BATCH_SIZE, output_path: nil)
      output = output_path ? File.open(output_path, "w") : $stdout
      csv = CSV.new(output)
      csv << HEADERS

      scope = Link.alive.where(Link.set_flag_sql(:has_same_rich_content_for_all_variants, false))
      scope = scope.where("links.id >= ?", start_link_id)
      scope = scope.where("links.id <= ?", end_link_id) if end_link_id

      total_scanned = 0
      total_suspect = 0
      scope.in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch
        batch.includes(:user, alive_variants: { alive_rich_contents: {}, product_files: {} }).each do |product|
          total_scanned += 1
          variants_with_content = product.alive_variants.select { |v| v.alive_rich_contents.any? }
          next if variants_with_content.size < 2

          canonical = file_id_signature(variants_with_content.first)
          next if canonical.empty? || canonical.size == 1
          next unless variants_with_content.all? { |v| file_id_signature(v) == canonical }

          csv << [
            product.id,
            product.unique_permalink,
            product.user&.email,
            variants_with_content.size,
            canonical.size,
            variants_with_content.first.alive_rich_contents.size,
          ]
          output.flush
          total_suspect += 1
        end
        puts "[#{self.class.name}] scanned=#{total_scanned} suspect=#{total_suspect} last_link_id=#{batch.maximum(:id)}"
      end

      puts "[#{self.class.name}] done. scanned=#{total_scanned} suspect=#{total_suspect}"
      { scanned: total_scanned, suspect: total_suspect }
    ensure
      output.close if output_path && output
    end

    private
      def file_id_signature(variant)
        variant.alive_rich_contents.flat_map(&:embedded_product_file_ids_in_order).uniq.sort
      end
  end
end
