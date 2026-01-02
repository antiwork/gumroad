# frozen_string_literal: true

class PaginatedInstallmentsPresenter
  include Pagy::Backend

  PER_PAGE = 25
  private_constant :PER_PAGE

  def initialize(seller:, type:, page: nil, query: nil)
    @type = type
    @seller = seller
    @page = [page.to_i, 1].max
    @query = query&.strip

    raise ArgumentError, "Invalid type" unless type.in? [Installment::PUBLISHED, Installment::SCHEDULED, Installment::DRAFT]
  end

  def props
    if query.blank?
      installments = Installment.includes(:installment_rule).all
      installments = installments.ordered_updates(seller, type).public_send(type)
      installments = installments.unscope(:order).order("installment_rules.to_be_published_at ASC") if type == Installment::SCHEDULED
      pagination, installments = pagy(installments, page:, limit: PER_PAGE, overflow: :empty_page)
      pagiation_metadata = { count: pagination.count, next: pagination.next }
    else
      offset = (page - 1) * PER_PAGE
      search_options = {
        exclude_deleted: true,
        type:,
        exclude_workflow_installments: true,
        seller:,
        q: query,
        fields: %w[name message],
        from: offset,
        size: PER_PAGE,
        sort: [:_score, { created_at: :desc }, { id: :desc }]
      }
      es_search = InstallmentSearchService.search(search_options)
      installments = es_search.records.load
      can_paginate_further = es_search.results.total > (offset + PER_PAGE)
      pagiation_metadata = { count: es_search.results.total, next: can_paginate_further ? page + 1 : nil }
    end

    current_seller = seller
    {
      installments: installments.map { InstallmentPresenter.new(seller:, installment: _1).props },
      pagination: pagiation_metadata,
      has_posts: current_seller.installments.alive.not_workflow_installment.public_send(type).exists?,
    }
  end

  private
    attr_reader :seller, :type, :page, :query
end
