# frozen_string_literal: true

class SocialProofWidgetMetric < ApplicationRecord
  belongs_to :social_proof_widget

  validates :impressions_count, :clicks_count, :closes_count, numericality: { greater_than_or_equal_to: 0 }
  validates :social_proof_widget_id, uniqueness: true

  # Methods for incrementing metrics atomically
  def self.increment_impressions(widget, amount = 1)
    find_or_create_for(widget).increment!(:impressions_count, amount)
  end

  def self.increment_clicks(widget, amount = 1)
    find_or_create_for(widget).increment!(:clicks_count, amount)
  end

  def self.increment_closes(widget, amount = 1)
    find_or_create_for(widget).increment!(:closes_count, amount)
  end

  def self.find_or_create_for(widget)
    find_or_create_by!(social_proof_widget: widget)
  end
end
