# frozen_string_literal: true

class PagesController < Sellers::BaseController
  before_action :require_pages_enabled
  before_action :set_page, only: [:edit, :update, :destroy, :publish, :unpublish, :generate]

  def index
    authorize Page
    pages = current_seller.pages.alive.order(updated_at: :desc)
    render inertia: "Pages/Index", props: {
      pages: pages.map { |p| page_json(p) },
      can_create_page: true,
    }
  end

  def new
    authorize Page
    product = current_seller.products.alive.find_by(unique_permalink: params[:product_id]) if params[:product_id]
    render inertia: "Pages/New", props: {
      product: product ? product_summary(product) : nil,
      products: current_seller.products.alive.not_is_bundle.published.order(name: :asc).map { |p| product_summary(p) },
    }
  end

  def create
    authorize Page
    page = current_seller.pages.build(
      title: params.dig(:page, :title),
    )
    page.link = current_seller.products.alive.find_by(unique_permalink: params.dig(:page, :product_permalink)) if params.dig(:page, :product_permalink).present?

    if page.save
      redirect_to edit_page_path(page.slug)
    else
      redirect_to new_page_path, alert: page.errors.full_messages.join(", ")
    end
  end

  def edit
    authorize @page
    render inertia: "Pages/Edit", props: edit_props
  end

  def update
    authorize @page
    if @page.update(page_update_params)
      render json: { success: true }
    else
      render json: { error_message: @page.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @page
    @page.mark_deleted!
    redirect_to pages_path
  end

  def publish
    authorize @page, :update?
    @page.publish!
    render json: { success: true }
  end

  def unpublish
    authorize @page, :update?
    @page.unpublish!
    render json: { success: true }
  end

  def generate
    authorize @page, :update?
    prompt = params[:prompt].to_s.strip
    return render json: { error: "Prompt cannot be blank" }, status: :unprocessable_entity if prompt.blank?

    result = Ai::PageGeneratorService.new(
      page: @page,
      seller: current_seller,
      prompt: prompt,
      parent_version: @page.latest_version,
    ).call

    if result.success?
      @page.update!(html_content: result.html)
      render json: { success: true, html: result.html, version_id: result.version.id }
    else
      render json: { success: false, error: result.error }, status: :unprocessable_entity
    end
  end

  private

  def require_pages_enabled
    head :not_found unless current_seller.pages_enabled?
  end

  def set_page
    @page = current_seller.pages.alive.find_by!(slug: params[:id])
  end

  def page_update_params
    params.require(:page).permit(:title, :slug, :html_content)
  end

  def page_json(page)
    {
      id: page.external_id,
      title: page.title,
      slug: page.slug,
      published: page.published,
      published_at: page.published_at&.iso8601,
      updated_at: page.updated_at.iso8601,
      product_name: page.link&.name,
    }
  end

  def product_summary(product)
    {
      id: product.external_id,
      name: product.name,
      permalink: product.unique_permalink,
      price: product.display_price,
      thumbnail_url: product.thumbnail&.alive&.url,
      short_url: product.short_url,
    }
  end

  def edit_props
    {
      page: {
        id: @page.external_id,
        title: @page.title,
        slug: @page.slug,
        html_content: @page.html_content,
        published: @page.published,
        published_at: @page.published_at&.iso8601,
        product: @page.link ? product_summary(@page.link) : nil,
      },
      products: current_seller.products.alive.not_is_bundle.published.order(name: :asc).map { |p| product_summary(p) },
      versions: @page.page_versions.order(created_at: :desc).limit(20).map { |v|
        { id: v.id, prompt: v.prompt, created_at: v.created_at.iso8601 }
      },
    }
  end
end
