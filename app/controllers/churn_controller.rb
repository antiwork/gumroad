# frozen_string_literal: true

class ChurnController < Sellers::BaseController
  layout "inertia"

  def show
    authorize :churn

    LargeSeller.create_if_warranted(current_seller)

    service = CreatorAnalytics::Churn.new(user: current_seller, params: params)

    render inertia: "Churn/Show",
           props: {
             churn_props: {
               has_subscription_products: service.has_subscription_products?,
               products: current_seller.products_for_creator_analytics.select(&:is_recurring_billing?).map do |product|
                 {
                   id: product.id,
                   name: product.name,
                   unique_permalink: product.unique_permalink,
                   alive: product.alive?
                 }
               end
             },
             churn_data: InertiaRails.optional { service.fetch_churn_data }
           }
  end
end
