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

  def update_purchases_content?
    update?
  end

  def shared_tab_permitted_attributes
    [
      :name,
      :custom_permalink
    ]
  end

  def product_tab_permitted_attributes
    shared_tab_permitted_attributes + [
      :description,
      :price_currency_type,
      :price_cents,
      :customizable_price,
      :suggested_price_cents,
      :max_purchase_count,
      :quantity_enabled,
      :should_show_sales_count,
      :hide_sold_out_variants,
      :is_epublication,
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
      :require_shipping,
      :is_multiseat_license,
      :community_chat_enabled,
      :default_offer_code_id,
      :custom_button_text_option,
      :custom_summary,
      refund_policy: [
        :max_refund_period_in_days,
        :title,
        :fine_print
      ],
      cancellation_discount: [
        :duration_in_billing_cycles,
        { discount: [:type, :cents, :percents] },
      ],
      call_limitation_info: [:minimum_notice_in_minutes, :maximum_calls_per_day],
      covers: [],
      custom_attributes: [
        :name,
        :value,
        :description
      ],
      file_attributes: [
        :name,
        :value
      ],
      public_files: [:id, :name, { status: [:type] }],
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
      installment_plan: [
        :number_of_installments,
      ]
    ]
  end

  def content_tab_permitted_attributes
    shared_tab_permitted_attributes + [
      :has_same_rich_content_for_all_variants,
      rich_content:,
      files: [:id, :display_name, :description, :folder_id, :size, :position, :url, :isbn,
              :extension, :stream_only, :pdf_stamp_enabled, :modified, subtitle_files: [:url, :language], thumbnail: [:signed_id]],
      variants: [
        :id,
        rich_content:,
      ],
    ]
  end

  def receipt_tab_permitted_attributes
    shared_tab_permitted_attributes + [
      :custom_receipt_text,
      :custom_view_content_button_text,
    ]
  end

  def share_tab_permitted_attributes
    shared_tab_permitted_attributes + [
      :is_adult,
      :display_product_reviews,
      :discover_fee_per_thousand,
      :taxonomy_id,
      :custom_domain,
      section_ids: [],
      tags: [],
    ]
  end

  def permitted_attributes
    product_permitted_attributes
  end

  def product_permitted_attributes
    (product_tab_permitted_attributes +
     content_tab_permitted_attributes +
     receipt_tab_permitted_attributes +
     share_tab_permitted_attributes).uniq
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
      :custom_view_content_button_text,
      :custom_receipt_text,
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
