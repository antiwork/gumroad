# frozen_string_literal: true

class HomeController < ApplicationController
  layout "home"

  allow_anonymous_access_to_helper_widget

  before_action :set_meta_data
  before_action :set_layout_and_title

  private
    def set_layout_and_title
      @hide_layouts = true
      @title = @meta_data[action_name]&.fetch(:title) || "Gumroad"
    end

    def set_meta_data
      @meta_data = {
        "about" => {
          url: :about_url,
          title: "Earn your first dollar online with Gumroad",
          description: "Start selling what you know, see what sticks, and get paid. Simple and effective."
        },
        "features" => {
          url: :features_url,
          title: "Gumroad features: Simple and powerful e-commerce tools",
          description: "Sell books, memberships, courses, and more with Gumroad's simple e-commerce tools. Everything you need to grow your audience."
        },
        "hackathon" => {
          url: :hackathon_url,
          title: "Gumroad $100K Niche Marketplace Hackathon",
          description: "Build a niche marketplace using Gumroad OSS. $100K in prizes for the best marketplace ideas and implementations."
        },
        "pricing" => {
          url: :pricing_url,
          title: "Gumroad pricing: 10% flat fee",
          description: "No monthly fees, just a simple 10% cut per sale. Gumroad's pricing is transparent and creator-friendly."
        },
        "privacy" => {
          url: :privacy_url,
          title: "Gumroad privacy policy: how we protect your data",
          description: "Learn how Gumroad collects, uses, and protects your personal information. Your privacy matters to us."
        },
        "prohibited" => {
          url: :prohibited_url,
          title: "Prohibited products on Gumroad",
          description: "Understand what products and activities are not allowed on Gumroad to comply with our policies."
        },
        "terms" => {
          url: :terms_url,
          title: "Gumroad terms of service",
          description: "Review the rules and guidelines for using Gumroad's services. Stay informed and compliant."
        }
      }
    end
end
