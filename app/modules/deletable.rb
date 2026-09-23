# frozen_string_literal: true

# Module for anything that uses soft deletion functionality.
module Deletable
  extend ActiveSupport::Concern

  included do
    scope :alive,   -> { where(deleted_at: nil) }
    scope :deleted, -> { where.not(deleted_at: nil) }
  end

  # Soft-deletes the record, raising on failure. `validate: false` skips model validations while
  # keeping the bang: the caller is deleting the row anyway, so a validation can only abort an
  # operation the caller has already decided on (account closure does this for every record the
  # account owns, where one legacy row that no longer validates must not block the closure).
  def mark_deleted!(validate: true)
    self.deleted_at = Time.current
    save!(validate:)
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
