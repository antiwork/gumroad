# frozen_string_literal: true

# AttributeBlockable provides a flexible system for checking if model attributes
# are blocked via the BlockedObject system, with support for efficient N+1 query
# prevention through eager loading.
#
# == Basic Usage
#
# To make an attribute blockable, use the +attr_blockable+ class method:
#
#   class User < ApplicationRecord
#     include AttributeBlockable
#
#     attr_blockable :email
#     attr_blockable :form_email_domain, object_type: :email
#   end
#
# This generates several instance methods:
# - +blocked_by_email?+ - Returns true if the email is blocked
# - +blocked_by_email_object+ - Returns the BlockedObject record
# - +block_by_email!+ - Blocks the email value
# - +unblock_by_email!+ - Unblocks the email value
#
# == Preventing N+1 Queries
#
# When loading multiple records that need blocked attribute checks, use
# +with_blocked_attributes_for+ to preload blocked status for all records
# in a single MongoDB query:
#
#   # Without preloading (N+1 queries)
#   users = User.where(verified: true)
#   users.each { |user| puts user.blocked_by_email? }
#
#   # With preloading (single query)
#   users = User.where(verified: true)
#               .with_blocked_attributes_for(:email, :email_domain)
#   users.each { |user| puts user.blocked_by_email? }
#
# == Caching
#
# The concern uses an instance variable to cache blocked status. This cache is
# automatically populated when using +with_blocked_attributes_for+ or lazily
# loaded on first access. The cache is cleared on +reload+.
#
# == Introspection
#
# The concern tracks all blockable attributes defined on a model:
#
#   User.blockable_attributes
#   # => [{ object_type: :email, blockable_method: :email },
#   #     { object_type: :email, blockable_method: :form_email }]
#
#   User.blockable_method_names
#   # => [:email, :form_email]
#
#   # Preload all blockable attributes automatically
#   User.with_all_blocked_attributes
#
# @example Admin controller with preloading
#   def index
#     @users = User.refund_queue
#                  .includes(:payments)
#                  .with_blocked_attributes_for(:form_email, :form_email_domain)
#   end
#
# @example Purchase model with multiple blockable attributes
#   class Purchase < ApplicationRecord
#     attr_blockable :email
#     attr_blockable :browser_guid
#     attr_blockable :ip_address
#     attr_blockable :charge_processor_fingerprint
#   end
#
module AttributeBlockable
  extend ActiveSupport::Concern

  # Returns the cache hash for blocked attribute lookups.
  # Structure: { "method_name" => blocked_object_or_nil }
  #
  # @return [Hash] Cache of blocked attribute statuses
  def blocked_by_attributes
    @blocked_by_attributes ||= {}.with_indifferent_access
  end

  def reload(*)
    @blocked_by_attributes = nil
    super
  end

  included do
    class_attribute :blockable_attributes, instance_writer: false, default: []
  end

  # Provides the +with_blocked_attributes_for+ scope method for ActiveRecord relations.
  module RelationMethods
    # Eagerly loads blocked attribute status for the specified methods.
    # This prevents N+1 queries by fetching all BlockedObjects in a single query.
    #
    # @param method_names [Array<Symbol, String>] Names of blockable attributes to preload
    # @return [ActiveRecord::Relation] Chainable relation with preloading configured
    #
    # @example Preload multiple attributes
    #   User.with_blocked_attributes_for(:email, :email_domain)
    #
    # @example Chain with other scopes
    #   User.where(verified: true)
    #       .with_blocked_attributes_for(:email)
    #       .order(created_at: :desc)
    def with_blocked_attributes_for(*method_names)
      spawn.tap { |relation| relation.extending!(BlockedAttributesPreloader.new(*method_names)) }
    end
  end

  # Internal module that handles the actual preloading logic by extending
  # ActiveRecord relations and hooking into query execution.
  #
  # @private
  class BlockedAttributesPreloader < Module
    # @param method_names [Array<Symbol, String>] Attribute names to preload
    def initialize(*method_names)
      @method_names = Array.wrap(method_names).map(&:to_s)
      super()
    end

    # Called when this module extends a relation. Sets up preloading hooks.
    #
    # @param relation [ActiveRecord::Relation] The relation being extended
    # @return [ActiveRecord::Relation] The extended relation
    def extended(relation)
      add_method_to_preload_list(relation)
      override_exec_queries(relation)
      define_preloading_methods(relation)
      relation
    end

    private
      # Adds method names to the relation's preload list, merging with any
      # existing methods from previous +with_blocked_attributes_for+ calls.
      def add_method_to_preload_list(relation)
        existing_methods = relation.instance_variable_get(:@_blocked_attributes_methods) || Set.new
        relation.instance_variable_set(:@_blocked_attributes_methods, Set.new(existing_methods + @method_names))
      end

      # Overrides the relation's +exec_queries+ method to trigger preloading
      # after records are fetched from the database.
      def override_exec_queries(relation)
        relation.define_singleton_method(:exec_queries) do |&block|
          @records = super(&block)
          preload_blocked_attributes! unless relation.instance_variable_get(:@_blocked_attributes_preloaded)
          @records
        end
      end

      # Defines the preloading methods on the relation instance.
      def define_preloading_methods(relation)
        # Iterates through all registered method names and preloads their blocked status
        relation.define_singleton_method(:preload_blocked_attributes!) do
          return if @records.blank?

          (@_blocked_attributes_methods || Set.new).each do |method_name|
            preload_blocked_attribute_for_method(method_name)
          end

          relation.instance_variable_set(:@_blocked_attributes_preloaded, true)
        end

        # Preloads blocked status for a single attribute across all records
        # in the relation using a single MongoDB query.
        #
        # @param method_name [String] The attribute method name
        relation.define_singleton_method(:preload_blocked_attribute_for_method) do |method_name|
          values = @records.filter_map { |record| record.try(method_name).presence }.uniq
          return if values.empty?

          # Look up the actual object type from the blockable_attributes registry
          # For example: form_email maps to :email, form_email_domain maps to :email_domain
          model_class = @records.first.class
          blockable_config = model_class.blockable_attributes.find { |attr| attr[:blockable_method] == method_name.to_sym }
          attribute_type = blockable_config ? blockable_config[:object_type] : method_name.to_sym

          scope = BLOCKED_OBJECT_TYPES.fetch(attribute_type, :all)
          blocked_objects_by_value = BlockedObject.send(scope).find_active_objects(values).index_by(&:object_value)

          @records.each do |record|
            value = record.send(method_name)
            blocked_object = blocked_objects_by_value[value]
            record.blocked_by_attributes[method_name] = blocked_object
          end
        end
      end
  end

  module ClassMethods
    # Defines blockable attribute methods for the given attribute.
    #
    # Generates the following instance methods:
    # - +blocked_by_{method}?+ - Returns true if the value is currently blocked
    # - +blocked_by_{method}_object+ - Returns the BlockedObject record
    # - +block_by_{method}!+ - Blocks the attribute value
    # - +unblock_by_{method}!+ - Unblocks the attribute value
    #
    # @param blockable_method [Symbol, String] The method name to make blockable
    # @param object_type [Symbol, String, nil] The BlockedObject type to use (defaults to blockable_method)
    #
    # @example Basic usage
    #   attr_blockable :email
    #   # user.blocked_by_email?
    #   # user.blocked_by_email_object&.blocked_at
    #   # user.block_by_email!(by_user_id: current_user.id)
    #
    # @example With custom attribute mapping
    #   attr_blockable :form_email, object_type: :email
    #   # Uses 'email' BlockedObject type but creates form_email methods
    #
    # @example Blocking with expiration
    #   user.block_by_email!(
    #     by_user_id: admin.id,
    #     expires_in: 30.days
    #   )
    def attr_blockable(blockable_method, object_type: nil)
      object_type ||= blockable_method

      define_method("blocked_by_#{blockable_method}?") { blocked_object_by_method(object_type, blockable_method:)&.blocked? || false }

      define_method("blocked_by_#{blockable_method}_object") do
        blocked_object_by_method(object_type, blockable_method:)
      end

      define_method("block_by_#{blockable_method}!") do |by_user_id: nil, expires_in: nil|
        return if (value = send(blockable_method)).blank?
        blocked_object = BlockedObject.block!(object_type, value, by_user_id, expires_in:)
        blocked_by_attributes[blockable_method.to_s] = blocked_object
      end

      define_method("unblock_by_#{blockable_method}!") do
        return if (value = send(blockable_method)).blank?
        scope = BLOCKED_OBJECT_TYPES.fetch(object_type.to_sym, :all)
        BlockedObject.send(scope).find_objects([value]).each do |blocked_object|
          blocked_object.unblock!
          blocked_by_attributes.delete(blockable_method.to_s)
        end
      end

      # Register this blockable attribute for introspection
      self.blockable_attributes = blockable_attributes + [{ object_type: object_type.to_sym, blockable_method: blockable_method.to_sym }]
    end

    # Returns an array of all blockable method names defined on this model.
    # Useful for automatically preloading all blockable attributes.
    #
    # @return [Array<Symbol>] Array of blockable method names
    #
    # @example
    #   User.blockable_method_names
    #   # => [:email, :form_email, :form_email_domain]
    def blockable_method_names
      blockable_attributes.map { |attr| attr[:blockable_method] }
    end

    # Preloads all registered blockable attributes for this model.
    # Convenience method that automatically calls +with_blocked_attributes_for+
    # with all blockable methods defined via +attr_blockable+.
    #
    # @return [ActiveRecord::Relation] Relation with all blockable attributes preloaded
    #
    # @example
    #   User.with_all_blocked_attributes
    #   # Equivalent to: User.with_blocked_attributes_for(:email, :form_email, :form_email_domain)
    def with_all_blocked_attributes
      with_blocked_attributes_for(*blockable_method_names)
    end

    # Class-level version of +with_blocked_attributes_for+ for use on model classes.
    #
    # @param method_names [Array<Symbol, String>] Names of blockable attributes to preload
    # @return [ActiveRecord::Relation] Relation with preloading configured
    #
    # @example
    #   User.with_blocked_attributes_for(:email, :email_domain)
    def with_blocked_attributes_for(*method_names)
      all.extending(RelationMethods).with_blocked_attributes_for(*method_names)
    end
  end

  def blocked_object_by_method(object_type, blockable_method: nil)
    blockable_method ||= object_type
    method_key = blockable_method.to_s

    return blocked_by_attributes[method_key] if blocked_by_attributes.key?(method_key)

    value = send(blockable_method)
    return if value.blank?

    blocked_object = blocked_object_for_value(object_type, value)
    blocked_by_attributes[method_key] = blocked_object
    blocked_object
  end

  # Retrieves BlockedObject records for the given values and attribute type.
  #
  # @param method_name [Symbol, String] The BlockedObject type
  # @param values [Array<String>] Values to look up
  # @return [Array<BlockedObject>] Array of BlockedObject records
  #
  # @example
  #   user.blocked_objects_for_values(:email, ['email1@example.com', 'email2@example.com'])
  def blocked_objects_for_values(method_name, values)
    scope = BLOCKED_OBJECT_TYPES.fetch(method_name.to_sym, :all)
    BlockedObject.send(scope).find_active_objects(values)
  end

  private
    # Retrieves a single BlockedObject for the given value.
    #
    # @param method_name [Symbol, String] The BlockedObject type
    # @param value [String] Value to look up
    # @return [BlockedObject, nil] The BlockedObject or nil if not found
    def blocked_object_for_value(method_name, value)
      scope = BLOCKED_OBJECT_TYPES.fetch(method_name.to_sym, :all)
      BlockedObject.send(scope).find_active_object(value)
    end
end
