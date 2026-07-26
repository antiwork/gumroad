# frozen_string_literal: true

# Runs a block after the current database transaction COMMITS, or immediately
# when there is no transaction open.
#
# Rails 7.1 has no public "run this after the transaction commits" hook for plain
# code — `after_commit` is an ActiveRecord *model* callback, and
# `connection.current_transaction` returns a transaction object that does not
# expose one. What the connection does accept is a record-like object
# (`add_transaction_record`), which it notifies with `committed!` on commit and
# `rolledback!` on rollback. This wraps that so callers can pass an ordinary
# block.
#
# Why bother instead of just writing inline: a write inside the transaction it is
# observing can be rolled back with it, which would leave an audit row
# describing a deletion that never happened — worse than no row. Deferring to
# commit means a row always describes data that really is gone.
class AfterCommitBlock
  def self.run(connection: ActiveRecord::Base.connection, &block)
    if connection.transaction_open?
      connection.add_transaction_record(new(&block))
    else
      block.call
    end
  end

  def initialize(&block)
    @block = block
  end

  # Called by the connection once the outermost transaction commits.
  def committed!(*)
    @block.call
  end

  # Called on rollback. Deliberately does nothing: the deletion this would have
  # described did not happen.
  def rolledback!(*)
    nil
  end

  # The connection skips notifying records that opt out of transactional
  # callbacks; this object always wants them.
  def trigger_transactional_callbacks?
    true
  end

  # `add_transaction_record` treats a record as "already in the transaction" via
  # this hook on some paths; nil is the neutral answer for a non-AR object.
  def before_committed!(*)
    nil
  end
end
