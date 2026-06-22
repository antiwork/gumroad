# frozen_string_literal: true

class ProfileSectionPolicy < ApplicationPolicy
  def create? = update?

  def update?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def destroy? = update?

  UPDATE_ATTRIBUTES = [:header, :default_product_sort, :add_new_products, :hide_header, :show_filters, :button_label, :featured_product_id, { shown_products: [], shown_posts: [], text: {}, shown_wishlists: [] }].freeze
  CREATE_ATTRIBUTES = [:type, :product_id, *UPDATE_ATTRIBUTES].freeze

  def permitted_attributes_for_create
    CREATE_ATTRIBUTES
  end

  def permitted_attributes_for_update
    UPDATE_ATTRIBUTES
  end
end
