# frozen_string_literal: true

class HomeController < ApplicationController
  layout "home"

  before_action :set_meta_data
  before_action :set_layout_and_title

  def about
    # Fetch root taxonomies (level 1 categories)
    @taxonomies = Taxonomy.where(parent_id: nil).where.not(slug: "other").limit(6)

    # Fetch featured products (alive, with taxonomy, ordered by recent updates)
    @featured_products = Link.alive
                             .joins(:taxonomy)
                             .includes(:user, :thumbnail, :asset_previews)
                             .where.not(draft: true)
                             .order(updated_at: :desc)
                             .limit(8)

    # Taxonomies for Discover header nav
    @taxonomies_for_nav = Discover::TaxonomyPresenter.new.taxonomies_for_nav
  end

  private
    def set_layout_and_title
      @hide_layouts = true
      @title = @meta_data[action_name]&.fetch(:title) || "Gumroad"
    end

    def set_meta_data
      @meta_data = {
        "about" => {
          url: :about_url,
          title: "AI Marketplace - Sàn giao dịch AI số 1 Việt Nam",
          description: "Khám phá, mua bán các sản phẩm AI: n8n workflows, prompts, khóa học, API keys và nhiều hơn nữa."
        },
        "features" => {
          url: :features_url,
          title: "Tính năng - Công cụ e-commerce đơn giản và mạnh mẽ",
          description: "Bán sách, khóa học, membership và nhiều hơn với công cụ e-commerce của Gumroad."
        },
        "hackathon" => {
          url: :hackathon_url,
          title: "Gumroad $100K Niche Marketplace Hackathon",
          description: "Build a niche marketplace using Gumroad OSS. $100K in prizes for the best marketplace ideas and implementations."
        },
        "pricing" => {
          url: :pricing_url,
          title: "Bảng giá - Phí 10% cho mỗi giao dịch",
          description: "Không phí hàng tháng, chỉ 10% cho mỗi giao dịch. Bảng giá minh bạch và thân thiện với người bán."
        },
        "privacy" => {
          url: :privacy_url,
          title: "Chính sách bảo mật",
          description: "Tìm hiểu cách chúng tôi thu thập, sử dụng và bảo vệ thông tin cá nhân của bạn."
        },
        "prohibited" => {
          url: :prohibited_url,
          title: "Sản phẩm bị cấm",
          description: "Tìm hiểu những sản phẩm và hoạt động không được phép trên nền tảng."
        },
        "terms" => {
          url: :terms_url,
          title: "Điều khoản dịch vụ",
          description: "Xem các quy tắc và hướng dẫn sử dụng dịch vụ của chúng tôi."
        },
        "small_bets" => {
          url: :small_bets_url,
          title: "Small Bets by Gumroad",
          description: "Explore the Small Bets initiative by Gumroad. Learn, experiment, and grow with small, actionable projects."
        }
      }
    end
end
