# frozen_string_literal: true

class SocialProofWidget < ApplicationRecord
  include Deletable

  CTA_TYPES = %w[button link none].freeze

  ALLOWED_ICONS = %w[
    icon_solid_fire
    icon_solid_heart
    icon_patch_check_fill
    icon_cart3_fill
    icon_solid_users
    icon_star_fill
    icon_solid_sparkles
    icon_clock_fill
    icon_solid_gift
    icon_solid_lightning_bolt
  ].freeze

  STATIC_IMAGE_TYPES = %w[
    product_thumbnail
    custom_image
  ].freeze

  IMAGE_TYPES = (STATIC_IMAGE_TYPES + ALLOWED_ICONS).freeze

  belongs_to :seller, class_name: "User", foreign_key: :seller_id

  has_one_attached :custom_image, dependent: :destroy
  has_many :social_proof_widgets_links, dependent: :destroy
  has_many :links, through: :social_proof_widgets_links
  has_one :metric, class_name: "SocialProofWidgetMetric", dependent: :destroy
  has_many :conversions, class_name: "SocialProofWidgetConversion", dependent: :destroy

  validates :name, :seller_id, :image_type, presence: true
  validates :cta_type, inclusion: { in: CTA_TYPES }
  validates :cta_text, presence: true, if: :cta_text_required?
  validates :image_type, inclusion: { in: IMAGE_TYPES }
  validate :custom_image_presence_if_required

  def custom_image_presence_if_required
    if image_type == "custom_image" && custom_image.attached?
      errors.add(:image, "must be attached when image_type is custom_image")
    end
  end

  def cta_text_required?
    return false if cta_type == "none"

    true
  end
end
