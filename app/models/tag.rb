# frozen_string_literal: true

class Tag < ApplicationRecord
  before_validation :clean_name, if: :name_changed?
  has_many :product_taggings, dependent: :destroy
  has_many :products, through: :product_taggings, class_name: "Link"

  validates :name,
            presence: true,
            uniqueness: { case_sensitive: true },
            length: { minimum: 2, too_short: "A tag is too short. Please try again with a longer one, above 2 characters.",
                      maximum: 20, too_long: "A tag is too long. Please try again with a shorter one, under 20 characters." },
            format: { with: /\A[^#,][^,]+\z/, message: "A tag cannot start with hashes or contain commas." }

  scope :by_text, lambda { |text: "", limit: 10|
    select("tags.*, COUNT(product_taggings.id) AS uses")
      .where("tags.name LIKE ?", "#{text.downcase}%")
      .joins("LEFT OUTER JOIN product_taggings ON product_taggings.tag_id = tags.id")
      .order("uses DESC")
      .order("tags.name ASC")
      .group("tags.id")
      .limit(limit)
  }

  def as_json(opts = {})
    if opts[:admin]
      { name:, humanized_name:, flagged: flagged?, id:, uses: product_taggings.count }
    else
      super(opts)
    end
  end

  def humanized_name
    self[:humanized_name] || name.titleize
  end

  def flag!
    self.flagged_at = Time.current
    save!
  end

  def flagged?
    flagged_at.present?
  end

  def unflag!
    self.flagged_at = nil
    save!
  end

  private
    def clean_name
      return if name.nil?
      self.name = name.downcase.strip.gsub(/[[:space:]]+/, " ")
    end
end
