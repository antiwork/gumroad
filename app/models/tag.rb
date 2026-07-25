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

  # Powers tag autocomplete (fires on every keystroke in the tag input).
  # Ranks matches by the taggings_count counter cache instead of joining and
  # counting product_taggings per request — short prefixes like "m%" match
  # thousands of tags, and the old LEFT JOIN + GROUP BY recomputed every
  # tag's usage count just to pick the top 10 (p99 was ~4.8s in production).
  # MySQL still sorts the prefix matches (the (name, taggings_count) index
  # can't serve this ORDER BY for a name range), but it's a covering-index
  # top-N sort over integers rather than a join + count across the whole
  # product_taggings table. The "uses" alias is kept because the frontend
  # reads it.
  scope :by_text, lambda { |text: "", limit: 10|
    select("tags.*, tags.taggings_count AS uses")
      .where("tags.name LIKE ?", "#{text.downcase}%")
      .order(taggings_count: :desc, name: :asc)
      .limit(limit)
  }

  def as_json(opts = {})
    if opts[:admin]
      { name:, humanized_name:, flagged: flagged?, id:, uses: taggings_count }
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
