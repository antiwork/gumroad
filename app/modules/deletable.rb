# frozen_string_literal: true

# Module for anything that uses soft deletion functionality.
module Deletable
  extend ActiveSupport::Concern

  included do
    scope :alive,   -> { where(deleted_at: nil) }
    scope :deleted, -> { where.not(deleted_at: nil) }
  end

  def mark_deleted!
    self.deleted_at = Time.current
    save!
  end

  def mark_deleted(validate: true)
    self.deleted_at = Time.current
    save(validate:)
  end

  def mark_undeleted!
    self.deleted_at = nil
    save!
  end

  def mark_undeleted
    self.deleted_at = nil
    save
  end

  def alive?
    deleted_at.nil?
  end
  alias_method :alive, :alive?

  def deleted?
    deleted_at.present?
  end

  def being_marked_as_deleted?
    deleted_at_changed?(from: nil)
  end
end
