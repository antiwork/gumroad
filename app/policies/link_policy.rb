# frozen_string_literal: true

# Products section
class LinkPolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def new?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def create?
    new?
  end

  def edit?
    return true if user.is_team_member?

    update?
  end

  def show?
    new?
  end

  def update?
    return true if user.collaborator_for?(record)
    return false if record.user != seller

    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def unpublish?
    new?
  end

  def publish?
    new?
  end

  def destroy?
    new?
  end

  def release_preorder?
    new?
  end

  def update_sections?
    update?
  end

  def product_permitted_attributes
    attributes = [
      :name,
      :description,
      :custom_permalink,
      :price_currency_type,
      :price_cents,
      :customizable_price,
      :suggested_price_cents,
      :max_purchase_count,
      :quantity_enabled,
      :should_show_sales_count,
      :hide_sold_out_variants,
      :custom_button_text_option,
      :custom_summary,
      :is_epublication,
      :display_product_reviews,
      :is_adult,
      :discover_fee_per_thousand,
      :taxonomy_id,
      :product_refund_policy_enabled,
      :seller_refund_policy_enabled,
      :custom_domain,
      :free_trial_enabled,
      :free_trial_duration_amount,
      :free_trial_duration_unit,
      :should_include_last_post,
      :should_show_all_posts,
      :block_access_after_membership_cancellation,
      :duration_in_months,
      :subscription_duration,
      :has_same_rich_content_for_all_variants,
      :require_shipping,
      :is_multiseat_license,
      :community_chat_enabled,
      refund_policy: [
        :max_refund_period_in_days,
        :title,
        :fine_print
      ],
      covers: [],
      custom_attributes: [
        :name,
        :value
      ],
      file_attributes: [
        :name,
        :value
      ],
      integrations: Integration::ALL_NAMES.index_with do |name|
        integration_class = Integration.class_for(name)
        [*integration_class.connection_settings, { integration_details: integration_class::INTEGRATION_DETAILS }]
      end,
      variants: [
        :id,
        :name,
        :description,
        :price_difference_cents,
        :max_purchase_count,
        :price_difference_cents,
        :duration_in_minutes,
        :customizable_price,
        :apply_price_changes_to_existing_memberships,
        :subscription_price_change_effective_date,
        :subscription_price_change_message,
        recurrence_price_values: BasePrice::Recurrence::PERMITTED_PARAMS,
        rich_content:,
        integrations: Integration::ALL_NAMES,
      ],
      availabilities: [
        :id,
        :start_time,
        :end_time,
      ],
      shipping_destinations: [
        :country_code,
        :one_item_rate_cents,
        :multiple_items_rate_cents,
      ],
      section_ids: [],
      tags: [],
      rich_content:,
      files: [:id, :display_name, :description, :folder_id, :size, :position, :url, :isbn,
              :extension, :stream_only, :pdf_stamp_enabled, :modified, subtitle_files: [:url, :language], thumbnail: [:signed_id]],
      call_limitation_info: [:minimum_notice_in_minutes, :maximum_calls_per_day],
      public_files: [:id, :name, status: [:type]],
      cancellation_discount: [
        { discount: [:type, :cents, :percents] },
        :duration_in_billing_cycles
      ],
      installment_plan: [
        :number_of_installments,
      ]
    ]

    attributes
  end

  def bundle_permitted_attributes
    [
      :name,
      :description,
      :custom_permalink,
      :price_cents,
      :customizable_price,
      :suggested_price_cents,
      :max_purchase_count,
      :quantity_enabled,
      :should_show_sales_count,
      :taxonomy_id,
      :display_product_reviews,
      :is_adult,
      :discover_fee_per_thousand,
      :custom_button_text_option,
      :custom_summary,
      :is_epublication,
      :product_refund_policy_enabled,
      :seller_refund_policy_enabled,
      refund_policy: [:max_refund_period_in_days, :title, :fine_print],
      section_ids: [],
      tags: [],
      covers: [],
      custom_attributes: [:name, :value],
      products: [:product_id, :variant_id, :quantity, :position],
      installment_plan: [:number_of_installments]
    ]
  end

  private
    def variant_shared_attributes
      [
        :id,
        :name,
        :description,
        :price_difference_cents,
        :max_purchase_count,
        rich_content:,
        integrations: Integration::ALL_NAMES,
      ]
    end

    def rich_content
      [:id, :title, :updated_at, { description: {} }]
    end
end
