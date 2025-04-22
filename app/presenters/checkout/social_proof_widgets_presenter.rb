# frozen_string_literal: true

class Checkout::SocialProofWidgetsPresenter
  include CheckoutDashboardHelper

  attr_reader :pundit_user, :social_proof_widgets, :pagination

  def initialize(pundit_user:, social_proof_widgets:, pagination:)
    @pundit_user = pundit_user
    @social_proof_widgets = social_proof_widgets
    @pagination = pagination
  end

  def social_proof_widgets_props
    {
      pages:,
      social_proof_widgets: social_proof_widgets.includes(
          :metric,
          :conversions,
        ).map { social_proof_widget_props(_1) },
      pagination:,
    }
  end

  private
    def social_proof_widget_props(social_proof_widget)
      impressions_count = social_proof_widget.metric&.impressions_count.to_i
      conversion_rate = impressions_count.zero? ? 0.0 : social_proof_widget.conversions.count / impressions_count.to_f

      {
        id: social_proof_widget.external_id,
        name: social_proof_widget.name,
        title: social_proof_widget.title,
        description: social_proof_widget.description,
        published: social_proof_widget.published,
        metric: social_proof_widget.metric,
        revenue: social_proof_widget.conversions.joins(:purchase).sum("purchases.amount"),
        conversion_rate: conversion_rate
      }
    end
end
