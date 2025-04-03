# frozen_string_literal: true

class MediaLocation < ApplicationRecord
  include MediaLocation::Unit
  include Platform
  include TimestampScopes

  belongs_to :product_file, optional: true
  belongs_to :purchase, optional: true

  scope :max_consumed_at_by_file, lambda { |purchase_id:|
    subquery = MediaLocation.select("product_file_id, MAX(consumed_at) AS max_consumed_at").where(purchase_id:).group(:product_file_id)
    join_sql = <<-SQL.squish
      INNER JOIN (#{subquery.to_sql}) AS max_ml
      ON media_locations.product_file_id = max_ml.product_file_id
      AND media_locations.consumed_at = max_ml.max_consumed_at
    SQL
    where(purchase_id:).joins(join_sql)
  }

  before_create :add_unit

  validate :file_is_consumable
  validates_presence_of :url_redirect_id, :product_file_id, :purchase_id, :location, :product_id
  validates :platform, inclusion: { in: Platform.all }

  def as_json(*)
    {
      location:,
      unit:,
      timestamp: consumed_at
    }
  end

  private
    def add_unit
      if product_file.streamable? || product_file.listenable?
        self.unit = Unit::SECONDS
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
