# frozen_string_literal: true

class Admin::ProductsController < Admin::BaseController
  before_action :fetch_product!

  def show
    @title = @product.name
    render inertia: "Admin/Products/Show", legacy_template: "admin/links/show", props: {
      title: @product.name,
      product: Admin::ProductPresenter::Card.new(product: @product, pundit_user:).props,
      user: Admin::UserPresenter::Card.new(user: @product.user, pundit_user:).props
    }
  end

  def destroy
    @product.delete!
    render json: { success: true }
  end

  def restore
    render json: { success: @product.update_attribute(:deleted_at, nil) }
  end

  def publish
    begin
      @product.publish!
    rescue Link::LinkInvalid, WithProductFilesInvalid
      return render json: { success: false, error_message: @product.errors.full_messages.join(", ") }
    rescue => e
      Bugsnag.notify(e)
      return render json: { success: false, error_message: I18n.t(:error_500) }
    end

    render json: { success: true }
  end

  def unpublish
    @product.unpublish!

    render json: { success: true }
  end

  def is_adult
    @product.is_adult = params[:is_adult]
    @product.save!

    render json: { success: true }
  end

  private
    def fetch_product!
      @product = Link.find_by(id: params[:id])
      @product || e404
    end
end
