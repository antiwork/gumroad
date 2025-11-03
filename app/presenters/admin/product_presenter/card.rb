# frozen_string_literal: true

class Admin::ProductPresenter::Card
  attr_reader :product, :admins_can_mark_as_staff_picked, :admins_can_unmark_as_staff_picked

  def initialize(product:, admins_can_mark_as_staff_picked:, admins_can_unmark_as_staff_picked:)
    @product = product
    @admins_can_mark_as_staff_picked = admins_can_mark_as_staff_picked
    @admins_can_unmark_as_staff_picked = admins_can_unmark_as_staff_picked
  end

  def props
    {
      id: product.id,
      name: product.name,
      long_url: product.long_url,
      price_cents: product.price_cents,
      currency_code: product.price_currency_type,
      unique_permalink: product.unique_permalink,
      preview_url: product.preview_url,
      cover_placeholder_url: ActionController::Base.helpers.asset_url("cover_placeholder.png"),
      price_formatted: product.price_formatted,
      created_at: product.created_at,
      user: {
        id: product.user_id,
        name: product.user.name,
        suspended: product.user.suspended?,
        flagged_for_tos_violation: product.user.flagged_for_tos_violation?
      },
      admins_can_generate_url_redirects: product.admins_can_generate_url_redirects,
      alive_product_files: alive_product_files_props,
      html_safe_description: product.html_safe_description,
      alive: product.alive?,
      is_adult: product.is_adult?,
      active_integrations: format_active_integrations,
      admins_can_mark_as_staff_picked: admins_can_mark_as_staff_picked.call(product),
      admins_can_unmark_as_staff_picked: admins_can_unmark_as_staff_picked.call(product),
      is_tiered_membership: product.is_tiered_membership?,
      updated_at: product.updated_at,
      deleted_at: product.deleted_at
    }
  end

  private
    def alive_product_files_props
      product.ordered_alive_product_files.map do |file|
        {
          id: file.id,
          external_id: file.external_id,
          s3_filename: file.s3_filename
        }
      end
    end

    def format_active_integrations
      product.active_integrations.map do |integration|
        {
          type: integration.type
        }
      end
    end
end
