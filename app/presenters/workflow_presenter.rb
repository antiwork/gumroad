# frozen_string_literal: true

class WorkflowPresenter
  include Rails.application.routes.url_helpers
  include ApplicationHelper

  attr_reader :seller, :workflow

  def initialize(seller:, workflow: nil)
    @seller = seller
    @workflow = workflow
  end

  def new_page_react_props
    { context: workflow_form_context_props }
  end

  def edit_page_react_props
    { workflow: workflow_props, context: workflow_form_context_props }
  end

  def workflow_props
    recipient_name = "All sales"
    if workflow.product_type?
      recipient_name = workflow.link.name
    elsif workflow.variant_type?
      recipient_name = "#{workflow.link.name} - #{workflow.base_variant.name}"
    elsif workflow.follower_type?
      recipient_name = "Followers only"
    elsif workflow.audience_type?
      recipient_name = "Everyone"
    elsif workflow.affiliate_type?
      recipient_name = "Affiliates only"
    end

    props = {
      name: workflow.name,
      external_id: workflow.external_id,
      workflow_type: workflow.workflow_type,
      workflow_trigger: workflow.workflow_trigger,
      recipient_name:,
      published: workflow.published_at.present?,
      first_published_at: workflow.first_published_at,
      send_to_past_customers: workflow.send_to_past_customers,
    }

    props[:installments] = workflow.installments.alive.joins(:installment_rule).order("delayed_delivery_time ASC").map { InstallmentPresenter.new(seller:, installment: _1).props }

    props.merge!(workflow.json_filters)
    if workflow.product_type? || workflow.variant_type?
      props[:unique_permalink] = workflow.link.unique_permalink
      props[:variant_external_id] = workflow.base_variant.external_id if workflow.variant_type?
    end

    if workflow.abandoned_cart_type?
      props[:abandoned_cart_products] = workflow.abandoned_cart_products
      props[:seller_has_products] = seller.links.visible_and_not_archived.exists?
    end

    props
  end

  def workflow_form_context_props
    user_presenter = UserPresenter.new(user: seller)

    {
      products_and_variant_options: user_presenter.products_for_filter_box.flat_map do |product|
        [{
          id: product.unique_permalink,
          label: product.name,
          product_permalink: product.unique_permalink,
          archived: product.archived?,
          type: "product",
        }].concat(
          (product.is_physical? ? product.skus_alive_not_default : product.alive_variants).map do
            {
              id: _1.external_id,
              label: "#{product.name} — #{_1.name}",
              product_permalink: product.unique_permalink,
              archived: product.archived?,
              type: "variant"
            }
          end
        )
      end,
      affiliate_product_options: user_presenter.affiliate_products_for_filter_box.map do |product|
        { id: product.unique_permalink, label: product.name, product_permalink: product.unique_permalink, archived: product.archived?, type: "product" }
      end,
      timezone: ActiveSupport::TimeZone[user_presenter.user.timezone].now.strftime("%Z"),
      currency_symbol: user_presenter.user.currency_symbol,
      countries: [Compliance::Countries::USA.common_name] + Compliance::Countries.for_select.flat_map { |_, name| Compliance::Countries::USA.common_name === name ? [] : name },
      aws_access_key_id: AWS_ACCESS_KEY,
      s3_url: s3_bucket_url,
      user_id: user_presenter.user.external_id,
      gumroad_address: GumroadAddress.full,
      eligible_for_abandoned_cart_workflows: user_presenter.user.eligible_for_abandoned_cart_workflows?,
    }
  end
end
