# frozen_string_literal: true

class HomeController < ApplicationController
  layout "home"

  before_action :hide_layouts

  def about
    set_meta_tag(title: "Earn your first dollar online with Gumroad")
    set_meta_tag(name: "description", content: "Start selling what you know, see what sticks, and get paid. Simple and effective.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: about_url, head_key: "canonical")
    set_meta_tag(property: "og:title", value: "Earn your first dollar online with Gumroad")
    set_meta_tag(property: "og:description", value: "Start selling what you know, see what sticks, and get paid. Simple and effective.")
    set_meta_tag(property: "og:type", value: "website")
    set_meta_tag(property: "og:url", content: about_url)
  end

  def features
    set_meta_tag(title: "Gumroad features: Simple and powerful e-commerce tools")
    set_meta_tag(name: "description", content: "Sell books, memberships, courses, and more with Gumroad's simple e-commerce tools. Everything you need to grow your audience.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: features_url, head_key: "canonical")
    set_meta_tag(property: "og:title", value: "Gumroad features: Simple and powerful e-commerce tools")
    set_meta_tag(property: "og:description", value: "Sell books, memberships, courses, and more with Gumroad's simple e-commerce tools. Everything you need to grow your audience.")
    set_meta_tag(property: "og:type", value: "website")
    set_meta_tag(property: "og:url", content: features_url)
  end

  def hackathon
    set_meta_tag(title: "Gumroad $100K Niche Marketplace Hackathon")
    set_meta_tag(name: "description", content: "Build a niche marketplace using Gumroad OSS. $100K in prizes for the best marketplace ideas and implementations.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: hackathon_url, head_key: "canonical")
    set_meta_tag(property: "og:title", value: "Gumroad $100K Niche Marketplace Hackathon")
    set_meta_tag(property: "og:description", value: "Build a niche marketplace using Gumroad OSS. $100K in prizes for the best marketplace ideas and implementations.")
    set_meta_tag(property: "og:type", value: "website")
    set_meta_tag(property: "og:url", content: hackathon_url)
  end

  def pricing
    set_meta_tag(title: "Gumroad pricing: 10% flat fee")
    set_meta_tag(name: "description", content: "No monthly fees, just a simple 10% cut per sale. Gumroad's pricing is transparent and creator-friendly.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: pricing_url, head_key: "canonical")
    set_meta_tag(property: "og:title", value: "Gumroad pricing: 10% flat fee")
    set_meta_tag(property: "og:description", value: "No monthly fees, just a simple 10% cut per sale. Gumroad's pricing is transparent and creator-friendly.")
    set_meta_tag(property: "og:type", value: "website")
    set_meta_tag(property: "og:url", content: pricing_url)
  end

  def privacy
    set_meta_tag(title: "Gumroad privacy policy: how we protect your data")
    set_meta_tag(name: "description", content: "Learn how Gumroad collects, uses, and protects your personal information. Your privacy matters to us.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: privacy_url, head_key: "canonical")
    set_meta_tag(property: "og:title", value: "Gumroad privacy policy: how we protect your data")
    set_meta_tag(property: "og:description", value: "Learn how Gumroad collects, uses, and protects your personal information. Your privacy matters to us.")
    set_meta_tag(property: "og:type", value: "website")
    set_meta_tag(property: "og:url", content: privacy_url)
  end

  def prohibited
    set_meta_tag(title: "Prohibited products on Gumroad")
    set_meta_tag(name: "description", content: "Understand what products and activities are not allowed on Gumroad to comply with our policies.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: prohibited_url, head_key: "canonical")
    set_meta_tag(property: "og:title", value: "Prohibited products on Gumroad")
    set_meta_tag(property: "og:description", value: "Understand what products and activities are not allowed on Gumroad to comply with our policies.")
    set_meta_tag(property: "og:type", value: "website")
    set_meta_tag(property: "og:url", content: prohibited_url)
  end

  def terms
    set_meta_tag(title: "Gumroad terms of service")
    set_meta_tag(name: "description", content: "Review the rules and guidelines for using Gumroad's services. Stay informed and compliant.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: terms_url, head_key: "canonical")
    set_meta_tag(property: "og:title", value: "Gumroad terms of service")
    set_meta_tag(property: "og:description", value: "Review the rules and guidelines for using Gumroad's services. Stay informed and compliant.")
    set_meta_tag(property: "og:type", value: "website")
    set_meta_tag(property: "og:url", content: terms_url)
  end

  def small_bets
    set_meta_tag(title: "Small Bets by Gumroad")
    set_meta_tag(name: "description", content: "Explore the Small Bets initiative by Gumroad. Learn, experiment, and grow with small, actionable projects.")
    set_meta_tag(tag_name: "link", rel: "canonical", href: small_bets_url, head_key: "canonical")
    set_meta_tag(property: "og:title", value: "Small Bets by Gumroad")
    set_meta_tag(property: "og:description", value: "Explore the Small Bets initiative by Gumroad. Learn, experiment, and grow with small, actionable projects.")
    set_meta_tag(property: "og:type", value: "website")
    set_meta_tag(property: "og:url", content: small_bets_url)
  end

  private
    def hide_layouts
      @hide_layouts = true
    end
end
