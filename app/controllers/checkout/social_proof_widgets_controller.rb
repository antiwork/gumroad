class Checkout::SocialProofWidgetsController < Sellers::BaseController
    before_action :set_social_proof_widget, only: [:show, :edit, :update, :destroy]

    def index
      authorize [:checkout, :social_proof]
      @social_proof_widgets = current_user.social_proof_widgets
    end

    def show
      authorize [:checkout, :social_proof]
    end

    def new
      authorize [:checkout, :social_proof]
      @social_proof_widget = SocialProofWidget.new
    end

    def create
      authorize [:checkout, :social_proof]

      selected_product_ids = social_proof_widget_params[:selected_product_ids]
      links = find_user_links(selected_product_ids)
      widget_params = social_proof_widget_params.except(:selected_product_ids)
      social_proof_widget = current_user.social_proof_widgets.build(links: links, **widget_params)

      if social_proof_widget.save
        presenter = Checkout::SocialProofPresenter.new(pundit_user:)
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

    def edit
      authorize [:checkout, :social_proof]
    end

    def update
      authorize [:checkout, :social_proof]

      if @social_proof_widget.update(social_proof_widget_params)
        # Update link associations
        if params[:link_ids].present?
          @social_proof_widget.link_ids = params[:link_ids]
        end

        render json: {
          success: true,
          message: "Social proof widget updated successfully",
          widget: @social_proof_widget
        }
      else
        render json: {
          success: false,
          errors: @social_proof_widget.errors.full_messages
        }, status: :unprocessable_entity
      end
    end

    def destroy
      authorize [:checkout, :social_proof]
      @social_proof_widget.destroy
      render json: { success: true, message: "Social proof widget deleted successfully" }
    end

    private
      def set_social_proof_widget
        @social_proof_widget = current_user.social_proof_widgets.find(params[:id])
      end

      def find_user_links(link_ids)
        return [] unless link_ids.present?

        link_ids.filter_map do |link_id|
          link = Link.find_by_external_id(link_id)
          link if link&.user_id == current_user.id
        end
      end

      def social_proof_widget_params
        params.require(:social_proof_widget).permit(
          :name,
          :universal,
          :title,
          :description,
          :cta_text,
          :cta_type,
          :image_type,
          :image_url,
          :icon_name,
          selected_product_ids: []
        )
      end

      def fetch_social_proof_widgets
        social_proof_widgets = current_user.social_proof_widgets.order(updated_at: :desc)

        social_proof_widgets
      end
  end
