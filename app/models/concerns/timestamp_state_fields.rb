# frozen_string_literal: true

# Implements ActiveRecord state fields based on timestamp columns.
#
# Requires a column to be named `property_at`, e.g., `verified_at`.
#
# `state` method uses reverse order of states to determine priority.  E.g., it
# checks the last state in the fields first to determine if the object is in
# that state.
#
# Example:
#
#   class User < ActiveRecord::Base
#     include TimestampStateFields
#     timestamp_state_fields :subscribed, :verified, default_state: :created
#   end
#
#   u = User.new
#   u.subscribed_at       # => "2015-11-15 22:51:13 -0800"
#   u.subscribed?         # => true
#   u.not_subscribed?     # => false
#   u.state               # => :subscribed
#   u.state_subscribed?   # => true
#   u.state_verified?     # => false
#   u.update_as_verified!
#   u.state               # => :verified
#   u.update_as_not_subscribed!
#
#   User.subscribed.count               # Number of subscribed users
#   User.subscribed.not_verified.count  # Number of unsubscribed users that are not verified
#
module TimestampStateFields
  extend ActiveSupport::Concern

  module ClassMethods
    def timestamp_state_fields(*names, default_state: :created, states_excluded_from_default: [])
      names.map(&:to_s).each do |name|
        column_name = "#{name}_at"

        define_singleton_method(:"#{name}") { where.not(column_name => nil) }
        define_singleton_method(:"not_#{name}") { where(column_name => nil) }

        define_method(:"#{name}?") { send(column_name).present? }
        define_method(:"not_#{name}?") { send(column_name).blank? }
        define_method(:"update_as_#{name}!") do |options = {}|
          update!(options.merge(column_name => Time.current))
        end
        define_method(:"update_as_not_#{name}!") do |options = {}|
          update!(options.merge(column_name => nil))
        end
        define_method(:"state_#{name}?") do
          state == name.to_sym
        end
      end

      define_method(:"state_#{default_state}?") do
        state == default_state
      end

      define_method(:state) do
        names.reverse_each do |name|
          next if states_excluded_from_default.include?(name)
          return name.to_sym if send(:"#{name}?")
        end
        default_state
      end
    end
  end
end
