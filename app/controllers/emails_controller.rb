# frozen_string_literal: true

class EmailsController < Sellers::BaseController
  layout "inertia", only: %i[published scheduled drafts]

  before_action :set_installment, only: %i[destroy]

  def index
    authorize Installment

    if current_seller.installments.alive.not_workflow_installment.scheduled.exists?
      redirect_to scheduled_emails_path, status: :moved_permanently
    else
      redirect_to published_emails_path, status: :moved_permanently
    end
  end

  # Legacy action for old React pages (new, edit) - will be migrated in PR 2
  def legacy
    authorize Installment, :index?
    create_user_event("emails_view")
    render "index"
  end

  def published
    authorize Installment, :index?
    create_user_event("emails_view")

    presenter = PaginatedInstallmentsPresenter.new(
      seller: current_seller,
      type: Installment::PUBLISHED,
      page: params[:page],
      query: params[:query],
    )
    render inertia: "Emails/Published", props: presenter.props
  end

  def scheduled
    authorize Installment, :index?
    create_user_event("emails_view")

    presenter = PaginatedInstallmentsPresenter.new(
      seller: current_seller,
      type: Installment::SCHEDULED,
      page: params[:page],
      query: params[:query],
    )
    render inertia: "Emails/Scheduled", props: presenter.props
  end

  def drafts
    authorize Installment, :index?
    create_user_event("emails_view")

    presenter = PaginatedInstallmentsPresenter.new(
      seller: current_seller,
      type: Installment::DRAFT,
      page: params[:page],
      query: params[:query],
    )
    render inertia: "Emails/Drafts", props: presenter.props
  end

  def destroy
    authorize @installment
    @installment.destroy
    redirect_to emails_path, notice: "Email deleted!", status: :see_other
  end

  private
    def set_title
      @title = "Emails"
    end

    def set_installment
      @installment = current_seller.installments.alive.find_by_external_id(params[:id])
      e404 unless @installment
    end
end
