# frozen_string_literal: true

class Community < ApplicationRecord
  include Deletable
  include ExternalId

  belongs_to :seller, class_name: "User"
  belongs_to :resource, polymorphic: true

  has_many :community_chat_messages, dependent: :destroy
  has_many :last_read_community_chat_messages, dependent: :destroy
  has_many :community_chat_recaps, dependent: :destroy

  validates :seller_id, uniqueness: { scope: [:resource_id, :resource_type, :deleted_at] }

  # SQL form of the `resource.alive? && resource.community_chat_enabled?` filter in
  # User#accessible_communities_ids. Joins `links`, so callers can join `purchases` onto it.
  scope :with_chat_enabled_product, -> {
    alive
      .joins("INNER JOIN links ON communities.resource_type = 'Link' AND communities.resource_id = links.id")
      .merge(Link.alive.community_chat_enabled)
  }

  def name = resource.name

  def thumbnail_url
    resource.for_email_thumbnail_url
  end
end
