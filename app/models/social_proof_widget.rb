# frozen_string_literal: true

class SocialProofWidget < ApplicationRecord
  has_paper_trail

  belongs_to :user

  # Association with links/products
  has_and_belongs_to_many :links

  # Analytics associations
  has_many :social_proof_widget_events, dependent: :destroy
  has_many :social_proof_widget_analytics, dependent: :destroy

  # Alias title_text to the `title` attribute to match the controller's transformation.
  alias_attribute :title_text, :title

  validates :name, presence: true
  validates :title, presence: true
  validates :cta_type, inclusion: { in: %w[button link none],
                                    message: "%{value} is not a valid CTA type" }
  validates :image_type, inclusion: {
    in: %w[
      product_thumbnail
      custom_image
      icon
      none
    ],
    message: "%{value} is not a valid image type"
  }
  validates :icon_name, inclusion: {
    in: %w[
      heart-fill
      star-fill
      gift-fill
      solid-star
      solid-bell
      solid-user
      cart3-fill
      check-square
      circle-fill
      bookmark-heart-fill
    ],
    message: "%{value} is not a valid icon name"
  }, if: -> { image_type == 'icon' }

    def status
    published? ? 'published' : 'unpublished'
  end

  def status=(value)
    self.published = (value == 'published')
  end

  scope :published, -> { where(published: true) }
  scope :unpublished, -> { where(published: false) }

  def display_template
    "#{title} - #{description} - CTA: #{cta_text}"
  end

  # Analytics methods
  def current_analytics(days = 30)
    SocialProofWidgetAnalytic.totals_for_widget(id, days.days.ago, Date.current)
  end



  def analytics_summary
    stats = current_analytics
    {
      clicks: stats[:clicks],
      conversion_rate: "#{stats[:conversion_rate]}%",
      revenue: "$#{(stats[:revenue_cents] / 100.0).round(2)}",
      status: status
    }
  end
end
