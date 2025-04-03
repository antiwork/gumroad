# frozen_string_literal: true

# An immutable ActiveRecord.
# Any model this module is included into will be immutable, except for
# any fields specified using `attr_mutable`.
#
# If you need to change an Immutable you should call `dup_and_save` or `dup_and_save!`.
module Immutable
  extend ActiveSupport::Concern

  included do
    include Deletable
    extend ClassMethods

    attr_mutable :deleted_at
    attr_mutable :updated_at

    before_update do
      changed_attributes_not_excluded = changed - self.class.attr_mutable_attributes
      raise RecordImmutable, changed_attributes_not_excluded if changed_attributes_not_excluded.present?
    end
  end

  module ClassMethods
    def attr_mutable_attributes
      @attr_mutable_attributes ||= []
    end

    def attr_mutable(attribute)
      attr_mutable_attributes << attribute.to_s
    end

    def perform_dup_and_save(record, block, raise_errors:)
      new_record = record.dup
      result = nil
      ActiveRecord::Base.transaction do
        block.call(new_record)
        result = record.mark_deleted(validate: false)
        raise ActiveRecord::Rollback unless result
        result = raise_errors ? new_record.save! : new_record.save
        raise ActiveRecord::Rollback unless result
      end
      [result, new_record]
    end
  end

  def dup_and_save(&block)
    self.class.perform_dup_and_save(self, block, raise_errors: false)
  end

  def dup_and_save!(&block)
    self.class.perform_dup_and_save(self, block, raise_errors: true)
  end

  class RecordImmutable < RuntimeError
    def initialize(attributes)
      super("The record is immutable but the attributes #{attributes} were attempted to be changed, but are not excluded from this models immutability.")
    end
  end
end
