# frozen_string_literal: true

class Subscriptions::MagicLinksController < ApplicationController
  before_action :fetch_subscription

  layout "inertia", only: [:new]

  def new
    render inertia: "Subscriptions/MagicLinks/New", props: {
      **Subscriptions::MagicLinkPresenter.new(subscription: @subscription).magic_link_props,
      email_sent: params[:email_sent]
    }
  end

  def create
    @subscription.refresh_token

    emails = @subscription.emails
    email_source = params[:email_source].to_sym
    email = emails[email_source]
    e404 if email.nil?

    CustomerMailer.subscription_magic_link(@subscription.id, email).deliver_later(queue: "critical")

    redirect_to new_subscription_magic_link_path(@subscription.external_id, email_sent: email_source),
                status: :see_other,
                notice: "Magic link sent to #{EmailRedactorService.redact(email)}"
  end

  private
    def fetch_subscription
      @subscription = Subscription.find_by_external_id(params[:subscription_id])
      e404 if @subscription.nil?
    end
end
