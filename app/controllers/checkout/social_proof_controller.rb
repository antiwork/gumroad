# frozen_string_literal: true

class Checkout::SocialProofController < Sellers::BaseController
    include Pagy::Backend

    PER_PAGE = 10

    def show
      authorize [:checkout, :social_proof]

      @title = "Social proof"
      @social_proof_props = Checkout::SocialProofPresenter.new(pundit_user:).social_proof_props
      @body_class = "fixed-aside"
      @products = current_seller.products.order(:name)

      render :index
    end

    def paged
      authorize [:checkout, :social_proof]

      pagination, social_proof_widgets = fetch_social_proof_widgets
      presenter = Checkout::SocialProofPresenter.new(pundit_user:)

      render json: {
        social_proof_widgets: social_proof_widgets.map { |widget| presenter.social_proof_widget_props(widget) },
        pagination:
      }
    end

    def create
      authorize [:checkout, :social_proof]

      permitted_params = social_proof_widget_params
      widget_attributes = {
        name: permitted_params[:name],
        universal: permitted_params[:universal],
        title: permitted_params[:title_text],
        description: permitted_params[:description],
        cta_text: permitted_params[:cta_text],
        cta_type: permitted_params.dig(:cta_type, :id),
        image_type: permitted_params.dig(:image, :id),
        icon_name: permitted_params[:icon],
        icon_color: permitted_params[:icon_color]
      }.compact

      social_proof_widget = current_user.social_proof_widgets.new(widget_attributes)

      # Set the status
      social_proof_widget.status = permitted_params[:status] || 'unpublished'

      if social_proof_widget.universal
        social_proof_widget.links = current_user.links.alive
      elsif permitted_params[:selected_product_ids].present?
        found_links = permitted_params[:selected_product_ids].filter_map do |link_id|
          link = Link.find_by_external_id(link_id)
          link if link&.user_id == current_user.id
        end
        social_proof_widget.links = found_links
      end

      if social_proof_widget.save
        render json: {
          success: true,
          social_proof_widgets: [social_proof_widget].map { |widget| presenter.social_proof_widget_props(widget) }
        }
      else
        render json: {
          success: false,
          error_message: social_proof_widget.errors.full_messages.first
        }
      end
    end

    def update
      authorize [:checkout, :social_proof]

      social_proof_widget = current_user.social_proof_widgets.find(params[:id])
      permitted_params = social_proof_widget_params

      widget_attributes = {
        name: permitted_params[:name],
        universal: permitted_params[:universal],
        title: permitted_params[:title_text],
        description: permitted_params[:description],
        cta_text: permitted_params[:cta_text],
        cta_type: permitted_params.dig(:cta_type, :id),
        image_type: permitted_params.dig(:image, :id),
        icon_name: permitted_params[:icon],
        icon_color: permitted_params[:icon_color]
      }.compact

      # Set the status
      social_proof_widget.status = permitted_params[:status] if permitted_params[:status].present?

      if social_proof_widget.update(widget_attributes)
        # Update product associations
        if social_proof_widget.universal
          social_proof_widget.links = current_user.links.alive
        elsif permitted_params[:selected_product_ids].present?
          found_links = permitted_params[:selected_product_ids].filter_map do |link_id|
            link = Link.find_by_external_id(link_id)
            link if link&.user_id == current_user.id
          end
          social_proof_widget.links = found_links
        end

        render json: {
          success: true,
          social_proof_widgets: [social_proof_widget].map { |widget| presenter.social_proof_widget_props(widget) }
        }
      else
        render json: {
          success: false,
          error_message: social_proof_widget.errors.full_messages.first
        }
      end
    rescue ActiveRecord::RecordNotFound
      render json: {
        success: false,
        error_message: "Social proof widget not found"
      }, status: :not_found
    end

        def destroy
      authorize [:checkout, :social_proof]

      social_proof_widget = current_user.social_proof_widgets.find(params[:id])

      if social_proof_widget.destroy
        render json: { success: true }
      else
        render json: {
          success: false,
          error_message: "Unable to delete social proof widget"
        }, status: :unprocessable_entity
      end
    rescue ActiveRecord::RecordNotFound
      render json: {
        success: false,
        error_message: "Social proof widget not found"
      }, status: :not_found
    end

    def track_event
      # Public endpoint - no authorization needed for customer tracking

      widget = SocialProofWidget.find(params[:widget_id])
      event_type = params[:event_type]
      session_id = params[:session_id] || session.id
      user_id = current_user&.id

      case event_type
      when 'impression'
        SocialProofWidgetEvent.track_impression(widget.id, session_id, user_id)
      when 'click'
        SocialProofWidgetEvent.track_click(widget.id, session_id, user_id)
      when 'purchase'
        purchase_id = params[:purchase_id]
        revenue_cents = params[:revenue_cents]
        SocialProofWidgetEvent.track_purchase(widget.id, session_id, purchase_id, revenue_cents, user_id)
      else
        return render json: { success: false, error_message: "Invalid event type" }, status: :bad_request
      end

      render json: { success: true }
    rescue ActiveRecord::RecordNotFound
      render json: { success: false, error_message: "Widget not found" }, status: :not_found
    rescue => e
      Rails.logger.error "Social proof tracking error: #{e.message}"
      render json: { success: false, error_message: "Tracking failed" }, status: :internal_server_error
    end

    private
      def parse_date_times
        # social_proof_widget_params[:valid_at] = Date.parse(social_proof_widget_params[:valid_at]) if social_proof_widget_params[:valid_at].present?
        # social_proof_widget_params[:expires_at] = Date.parse(social_proof_widget_params[:expires_at]) if social_proof_widget_params[:expires_at].present?
      end

      def social_proof_widget_params
        params
          .permit(
            :name,
            :universal,
            :titleText,
            :description,
            :ctaText,
            :icon,
            :iconColor,
            :status,
            { ctaType: [:id, :label] },
            { image: [:id, :label] },
            selectedProductIds: []
          )
          .transform_keys(&:underscore)
      end

      def presenter
        Checkout::SocialProofPresenter.new(pundit_user:)
      end

      def fetch_social_proof_widgets
        # Map user-facing query params to internal params
        params[:sort] = { key: params[:column], direction: params[:sort] } if params[:column].present? && params[:sort].present?

        social_proof_widgets = current_seller.social_proof_widgets
                                  .includes(:links)
                                  .order(updated_at: :desc)

        # Apply sorting
        if params[:sort].present? && params[:sort][:key].present?
          case params[:sort][:key]
          when "name"
            social_proof_widgets = social_proof_widgets.order(name: params[:sort][:direction])
          when "clicks", "conversion", "revenue", "status"
            # For now, these will use default sorting
            # Later can be enhanced with actual statistics
            social_proof_widgets = social_proof_widgets.order(updated_at: params[:sort][:direction])
          end
        end

        # Apply search query
        if params[:query].present?
          social_proof_widgets = social_proof_widgets.where("name LIKE ?", "%#{params[:query]}%")
        end

        social_proof_widgets_count = social_proof_widgets.count

        # Map invalid page numbers to the closest valid page number
        total_pages = (social_proof_widgets_count / PER_PAGE.to_f).ceil
        page_num = params[:page].to_i
        if page_num <= 0
          page_num = 1
        elsif page_num > total_pages && total_pages != 0
          page_num = total_pages
        end

        pagination, social_proof_widgets = pagy(social_proof_widgets, page: page_num, limit: PER_PAGE)

        [PagyPresenter.new(pagination).props, social_proof_widgets]
      end
  end
