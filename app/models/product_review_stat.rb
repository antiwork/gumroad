# frozen_string_literal: true

class ProductReviewStat < ApplicationRecord
  belongs_to :link, optional: true

  validates_presence_of :link
  validates_uniqueness_of :link_id

  RATING_COLUMN_MAP = {
    1 => "ratings_of_one_count",
    2 => "ratings_of_two_count",
    3 => "ratings_of_three_count",
    4 => "ratings_of_four_count",
    5 => "ratings_of_five_count"
  }.freeze
  TEMPLATE = new.freeze

  def rating_counts
    RATING_COLUMN_MAP.transform_values { |column| attributes[column] }
  end

  def rating_percentages
    return rating_counts if reviews_count.zero?

    percentages = rating_counts.transform_values { (_1.to_f / reviews_count) * 100 }

    # Increment ratings with the largest remainder so the total percentage is 100
    remainders = percentages.map { |rating, percentage| [percentage % 1, rating] }.sort.reverse
    threshold = remainders.sum(&:first).round
    remainders[0...threshold].each { |_, rating| percentages[rating] += 1 }

    percentages.transform_values(&:floor)
  end

  def update_with_added_rating(rating)
    rating_column = RATING_COLUMN_MAP[rating]
    update_ratings("#{rating_column} = #{rating_column} + 1")
  end

  def update_with_changed_rating(old_rating, new_rating)
    old_rating_column = RATING_COLUMN_MAP[old_rating]
    new_rating_column = RATING_COLUMN_MAP[new_rating]
    update_ratings("#{old_rating_column} = #{old_rating_column} - 1, #{new_rating_column} = #{new_rating_column} + 1")
  end

  def update_with_removed_rating(rating)
    rating_column = RATING_COLUMN_MAP[rating]
    update_ratings("#{rating_column} = #{rating_column} - 1")
  end

  private
    REVIEWS_COUNT_SQL = RATING_COLUMN_MAP.values.join(" + ").freeze
    RATING_TOTAL_SQL = RATING_COLUMN_MAP.map { |value, column| "#{column} * #{value}" }.join(" + ").freeze
    AVERAGE_RATING_SQL = "ROUND((#{RATING_TOTAL_SQL}) / reviews_count, 1)"

    def update_ratings(assignment_list_sql)
      self.class.where(id:).update_all <<~SQL.squish
        #{assignment_list_sql},
        reviews_count = #{REVIEWS_COUNT_SQL},
        average_rating = #{AVERAGE_RATING_SQL},
        updated_at = "#{Time.current.to_fs(:db)}"
      SQL
      reload
    end
end
