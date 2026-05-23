# frozen_string_literal: true

module SalesRelatedProductsInfosHelpers
  def rebuild_srpis_cache
    CachedSalesRelatedProductsInfo.delete_all
    Link.ids.each do
      UpdateCachedSalesRelatedProductsInfosJob.new.perform(_1)
    end
  end
end
