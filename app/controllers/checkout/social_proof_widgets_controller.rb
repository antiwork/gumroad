class SocialProofWidgetsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_social_proof_widget, only: [:show, :edit, :update, :destroy]

    def index
      @social_proof_widgets = current_user.social_proof_widgets
    end

    def show
    end

    def new
      @social_proof_widget = SocialProofWidget.new
    end

    def create
      authorize [:social_proof_widget]

      selected_product_ids = social_proof_widget_params[:selected_product_ids]
      products = current_seller.products.by_external_ids(selected_product_ids)
      widget_params = social_proof_widget_params.except(:selected_product_ids)
      social_proof_widget = current_seller.social_proof_widgets.build(products: products, **widget_params)

      if social_proof_widget.save
        render json: {
          success: true,
          social_proof_widgets: social_proof_widget.map { presenter.social_proof_widget_props(_1) }
        }
      else
        render json: {
          success: false,
          error_message: social_proof_widget.errors.full_messages.first
        }
      end
    end

    def edit
    end

    def update
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
      @social_proof_widget.destroy
      render json: { success: true, message: "Social proof widget deleted successfully" }
    end

    private
      def set_social_proof_widget
        @social_proof_widget = SocialProofWidget.find(params[:id])
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
          :icon_name
        )
      end

      def fetch_social_proof_widgets
        social_proof_widgets = current_seller.social_proof_widgets.order(updated_at: :desc)

        social_proof_widgets
      end
  end
