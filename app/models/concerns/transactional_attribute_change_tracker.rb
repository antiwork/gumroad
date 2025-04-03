# frozen_string_literal: true

# Tracks all the attributes that were changed in a transaction,
# and makes them available in `#attributes_committed` when the transaction is committed.
# This module exists because `previous_changes` only contains the attributes that were changed in the last `save`,
# if the record was not `reload`ed during the transaction.
# Caveats:
# - if an attribute is saved twice in the same transaction, and goes back to its original value, it will still be tracked in `#attributes_committed`
module TransactionalAttributeChangeTracker
  extend ActiveSupport::Concern

  included do
    attr_reader :attributes_committed

    after_save do
      @attributes_committed = nil
      (@attributes_changed_in_transaction ||= Set.new).merge(previous_changes.keys)
    end

    before_commit do
      next unless @attributes_changed_in_transaction
      @attributes_committed = @attributes_changed_in_transaction.to_a
      @attributes_changed_in_transaction.clear
    end
  end
end
