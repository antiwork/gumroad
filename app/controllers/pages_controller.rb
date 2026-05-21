# frozen_string_literal: true

class PagesController < Sellers::BaseController
  before_action :require_pages_enabled
  before_action :set_page, only: [:edit, :update, :destroy, :publish, :unpublish, :generate, :latest_version]

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
      products: current_seller.products.alive.not_is_bundle.order(name: :asc).map { |p| product_summary(p) },
      templates: Ai::PageTemplates.public_list,
    }
  end

  def templates
    authorize Page
    render json: { templates: Ai::PageTemplates.public_list }
  end

  def create
    authorize Page
    page = current_seller.pages.build(
      title: params.dig(:page, :title),
      is_profile: ActiveModel::Type::Boolean.new.cast(params.dig(:page, :is_profile)) || false,
    )
    page.link = current_seller.products.alive.find_by(unique_permalink: params.dig(:page, :product_permalink)) if params.dig(:page, :product_permalink).present?

    initial_prompt = resolve_initial_prompt(page)

    if page.save
      Pages::GeneratePageVersionJob.perform_async(page.id, initial_prompt, nil) if initial_prompt.present?
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
    version = params[:version_id].present? ? @page.page_versions.find_by(id: params[:version_id]) : nil
    @page.update!(auto_publish: true) if ActiveModel::Type::Boolean.new.cast(params[:auto_publish])
    @page.publish!(version: version)
    render json: { success: true, published_version_id: @page.published_version_id }
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  def unpublish
    authorize @page, :update?
    @page.update!(auto_publish: false) if ActiveModel::Type::Boolean.new.cast(params[:disable_auto_publish])
    @page.unpublish!
    render json: { success: true }
  end

  def generate
    authorize @page, :update?
    prompt = params[:prompt].to_s.strip
    return render json: { error: "Prompt cannot be blank" }, status: :unprocessable_entity if prompt.blank?

    moderation = moderate_prompt(@page, prompt)
    return render json: { success: false, error: "Content moderation blocked this prompt." }, status: :unprocessable_entity unless moderation.passed

    Pages::GeneratePageVersionJob.perform_async(@page.id, prompt, @page.latest_version&.id)
    render json: { success: true, queued: true }
  end

  def latest_version
    authorize @page, :edit?
    version = @page.latest_version
    render json: {
      html_content: @page.html_content,
      latest_version: version ? { id: version.id, prompt: version.prompt, created_at: version.created_at.iso8601 } : nil,
      published_version_id: @page.published_version_id,
      published: @page.published,
      auto_publish: @page.auto_publish,
      generating: version.nil? && @page.html_content.blank? && @page.generation_error.blank?,
      generation_error: @page.generation_error,
    }
  end

  private
    def require_pages_enabled
      head :not_found unless current_seller.pages_enabled?
    end

    def set_page
      @page = current_seller.pages.alive.find_by!(slug: params[:id])
    end

    def page_update_params
      # html_content is only written by Pages::GeneratePageVersionJob via apply_new_version!
      # (and by publish! when a prior version is promoted). Letting clients PUT it directly
      # would bypass Ai::PageSanitizer.
      params.require(:page).permit(:title, :slug, :is_profile, :auto_publish)
    end

    def resolve_initial_prompt(page)
      if params.dig(:page, :template_id).present?
        Ai::PageTemplates.prompt_for(params.dig(:page, :template_id))
      elsif params.dig(:page, :initial_prompt).present?
        params.dig(:page, :initial_prompt).to_s.strip.presence
      elsif page.link.present?
        "Create a landing page for #{page.link.name}. Highlight the product, include a buy button, and showcase what makes it valuable."
      end
    end

    # Build a transient Page stand-in whose `html_content` carries the prompt
    # so ContentExtractor#extract_from_page picks it up without mutating the
    # persisted page (which would clobber a real version with the user's
    # natural-language string).
    def moderate_prompt(page, prompt)
      proxy = Page.new(user: page.user, title: page.title, html_content: prompt)
      ContentModeration::ModerateRecordService.check(proxy, :page)
    end

    def page_json(page)
      {
        id: page.external_id,
        title: page.title,
        slug: page.slug,
        published: page.published,
        published_at: page.published_at&.iso8601,
        updated_at: page.updated_at.iso8601,
        is_profile: page.is_profile,
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
        short_url: product.long_url,
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
          published_version_id: @page.published_version_id,
          auto_publish: @page.auto_publish,
          is_profile: @page.is_profile,
          product: @page.link ? product_summary(@page.link) : nil,
        },
        products: current_seller.products.alive.not_is_bundle.order(name: :asc).map { |p| product_summary(p) },
        templates: Ai::PageTemplates.public_list,
        versions: @page.page_versions.order(created_at: :desc).limit(20).map do |v|
          { id: v.id, prompt: v.prompt, created_at: v.created_at.iso8601 }
        end,
      }
    end
end
