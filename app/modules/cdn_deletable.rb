# frozen_string_literal: true

module CdnDeletable
  extend ActiveSupport::Concern

  included do
    scope :alive_in_cdn, -> { where(deleted_from_cdn_at: nil) }
    scope :cdn_deletable, -> { s3.deleted.alive_in_cdn }
  end

  def deleted_from_cdn?
    deleted_from_cdn_at.present?
  end

  def mark_deleted_from_cdn
    update_column(:deleted_from_cdn_at, Time.current)
  end
end
