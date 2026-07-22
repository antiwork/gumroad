# frozen_string_literal: true

class MediaLocation < ApplicationRecord
  include MediaLocation::Unit
  include Platform
  include TimestampScopes

  belongs_to :product_file, optional: true
  belongs_to :purchase, optional: true

  MAX_EPUB_CFI_LENGTH = 1_024
  EPUB_CFI_STEP_PATTERN = %r{/\d+(?:\[(?:\^.|[^\]\r\n^])*+\])?}
  EPUB_CFI_PATTERN = /\Aepubcfi\((?:#{EPUB_CFI_STEP_PATTERN}){2,}!(?:#{EPUB_CFI_STEP_PATTERN})+(?:[^\r\n()]*)\)\z/

  scope :max_consumed_at_by_file, lambda { |purchase_id:, product_file_ids: nil, unit: nil|
    records = MediaLocation.where(purchase_id:)
    records = records.where(product_file_id: product_file_ids) if product_file_ids.present?
    records = records.where(unit:) if unit.present?
    subquery = records.select("product_file_id, MAX(consumed_at) AS max_consumed_at").group(:product_file_id)
    join_sql = <<-SQL.squish
      INNER JOIN (#{subquery.to_sql}) AS max_ml
      ON media_locations.product_file_id = max_ml.product_file_id
      AND media_locations.consumed_at = max_ml.max_consumed_at
    SQL
    records.joins(join_sql)
  }

  # Batched variant of max_consumed_at_by_file for serializing many purchases in one
  # request (e.g. the mobile purchases list/search endpoints). Returns, in a single
  # query, the most-recently-consumed media location per (purchase, product file)
  # pair across all the given purchases — callers group the result by purchase_id.
  # Without this, each purchase issues its own max_consumed_at_by_file query, which
  # is the N+1 Sentry flags on Api::Mobile::PurchasesController.
  scope :max_consumed_at_by_file_for_purchases, lambda { |purchase_ids:|
    subquery = MediaLocation.select("purchase_id, product_file_id, MAX(consumed_at) AS max_consumed_at")
                            .where(purchase_id: purchase_ids)
                            .group(:purchase_id, :product_file_id)
    join_sql = <<-SQL.squish
      INNER JOIN (#{subquery.to_sql}) AS max_ml
      ON media_locations.purchase_id = max_ml.purchase_id
      AND media_locations.product_file_id = max_ml.product_file_id
      AND media_locations.consumed_at = max_ml.max_consumed_at
    SQL
    where(purchase_id: purchase_ids).joins(join_sql)
  }

  before_validation :add_unit

  validate :file_is_consumable
  validates_presence_of :url_redirect_id, :product_file_id, :purchase_id, :location, :product_id
  validates :platform, inclusion: { in: Platform.all }
  validates :epub_cfi, length: { maximum: MAX_EPUB_CFI_LENGTH }, format: { with: EPUB_CFI_PATTERN }, allow_nil: true
  validates :location, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, if: :epub_location?

  def self.valid_epub_cfi?(value)
    value.is_a?(String) && value.length <= MAX_EPUB_CFI_LENGTH && value.match?(EPUB_CFI_PATTERN)
  end

  def self.valid_epub_percentage?(value)
    number = Float(value, exception: false)
    number.present? && number.between?(0, 100)
  end

  def as_json(options = nil)
    attributes = {
      location:,
      unit:,
      timestamp: consumed_at
    }
    include_epub_cfi = options.nil? || options.fetch(:include_epub_cfi, true)
    attributes[:cfi] = epub_cfi if include_epub_cfi && epub_cfi.present?
    attributes
  end

  private
    def epub_location?
      unit == Unit::PERCENTAGE && epub_cfi.present?
    end

    def add_unit
      if product_file.streamable? || product_file.listenable?
        self.unit = Unit::SECONDS
      elsif product_file.epub? && epub_cfi.present?
        self.unit = Unit::PERCENTAGE
      elsif product_file.readable?
        self.unit = Unit::PAGE_NUMBER
      else
        self.unit = Unit::PERCENTAGE
      end
    end

    def file_is_consumable
      return if product_file.consumable?

      errors.add(:base, "File should be consumable")
    end
end
