# frozen_string_literal: true

class Subscriptions::MagicLinksController < ApplicationController
  include InertiaRendering, PageMeta::Base

  before_action :fetch_subscription
  before_action :set_csrf_meta_tags
  before_action :set_default_meta_tags
  before_action :hide_layouts
  helper_method :erb_meta_tags

  layout "inertia", only: [:new]

  def new
    set_meta_tag(title: @subscription.is_installment_plan ? "Manage installment plan" : "Manage membership")
    render inertia: "Subscriptions/MagicLinks/New", props: magic_link_props
  end

  def create
    @subscription.refresh_token

    emails = @subscription.emails
    email_source = params[:email_source].to_sym
    email = emails[email_source]
    e404 if email.nil?

    CustomerMailer.subscription_magic_link(@subscription.id, email).deliver_later(queue: "critical")

    head :no_content
  end

  private
    def fetch_subscription
      @subscription = Subscription.find_by_external_id(params[:id])
      e404 if @subscription.nil?
    end

    def magic_link_props
      unique_emails = @subscription.emails.map do |source, email|
        { email: EmailRedactorService.redact(email), source: } unless email.nil?
      end.compact.uniq { |email| email[:email] }

      {
        subscription_id: @subscription.external_id,
        is_installment_plan: @subscription.is_installment_plan,
        user_emails: unique_emails,
        product_name: @subscription.link.name
      }
    end
end
