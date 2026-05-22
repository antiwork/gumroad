# frozen_string_literal: true

class PagesController < Sellers::BaseController
  before_action :require_pages_enabled
  before_action :set_page, only: [:edit, :update, :destroy, :publish, :unpublish, :generate, :latest_version]

  def index
    authorize Page
    # Scoped lookup: "does this product/profile already have a page?"
    # Callers pass either ?product_id=<unique_permalink> or ?is_profile=true.
    # Returns a single-entry array (or empty) keeping the contract narrow —
    # we never need the seller's full page list anymore now that the Pages
    # nav surface is gone.
    pages = current_seller.pages.alive.includes(:link)
    if params[:product_id].present?
      product = current_seller.products.alive.find_by(unique_permalink: params[:product_id])
      pages = product ? pages.where(link_id: product.id) : pages.none
    elsif ActiveModel::Type::Boolean.new.cast(params[:is_profile])
      pages = pages.where(is_profile: true)
    else
      return render json: { error: "product_id or is_profile required" }, status: :bad_request
    end
    render json: { pages: pages.map { |p| page_json(p) } }
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
      # Seed v1 with a snapshot of the currently rendered product/profile so
      # the editor opens on the real page rather than a blank chat. The first
      # AI iteration branches off this baseline (parent_version: v1) so the
      # model can "evolve" the existing page rather than generate from scratch.
      seed_version = Ai::InitialPageSnapshot.create_for!(page)

      if initial_prompt.present?
        page.update_column(:generating_since, Time.current)
        Pages::GeneratePageVersionJob.perform_async(page.id, initial_prompt, seed_version&.id)
      end
      respond_to do |format|
        format.html { redirect_to edit_page_path(page.slug) }
        format.json { render json: { success: true, edit_url: edit_page_path(page.slug), id: page.external_id, slug: page.slug } }
      end
    else
      respond_to do |format|
        format.html { redirect_back fallback_location: products_path, alert: page.errors.full_messages.join(", ") }
        format.json { render json: { success: false, error: page.errors.full_messages.join(", ") }, status: :unprocessable_entity }
      end
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
    fallback = if @page.link
                 edit_link_path(@page.link.unique_permalink)
               else
                 products_path
               end
    @page.mark_deleted!
    respond_to do |format|
      format.html { redirect_back fallback_location: fallback, notice: "Page deleted." }
      format.json { render json: { success: true, redirect_url: fallback } }
    end
  end

  def publish
    authorize @page, :update?
    version = nil
    if params[:version_id].present?
      version = @page.page_versions.find_by(id: params[:version_id])
      return render json: { success: false, error: "Version not found" }, status: :unprocessable_entity if version.nil?
    end
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
    return render json: { success: false, error: "This prompt isn't allowed. Try wording it differently." }, status: :unprocessable_entity unless moderation.passed

    # Flip the page into generating state *before* enqueuing so a fast worker
    # can't complete the job and clear generating_since before we set it.
    # Also clear any stale generation_error so the spinner isn't accompanied by
    # the previous run's error message during the poll window.
    @page.update_columns(generating_since: Time.current, generation_error: nil)
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
      generating: @page.generating_since.present?,
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
      # :slug is intentionally not permitted — renaming the slug silently breaks every
      # published URL pointing at the old one. Slugs are immutable post-creation.
      params.require(:page).permit(:title, :is_profile, :auto_publish)
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
          generating: @page.generating_since.present?,
          generation_error: @page.generation_error,
          product: @page.link ? product_summary(@page.link) : nil,
          page_url: @page.page_url,
        },
        products: current_seller.products.alive.not_is_bundle.order(name: :asc).map { |p| product_summary(p) },
        templates: Ai::PageTemplates.public_list,
        versions: @page.page_versions.order(created_at: :desc).limit(20).map do |v|
          { id: v.id, prompt: v.prompt, created_at: v.created_at.iso8601 }
        end,
      }
    end
end
