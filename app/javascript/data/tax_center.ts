import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export type TaxDocument = {
  document: string;
  type: string;
  year: number;
  form_type: string;
  gross: string;
  fees: string;
  taxes: string;
  affiliate_credit?: string;
  net: string;
};

export type TaxDocumentsData = {
  documents: TaxDocument[];
  available_years: number[];
  selected_year: number;
};

export const getTaxDocuments = (year: number) => {
  const abort = new AbortController();

  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.internal_tax_documents_path({ year }),
    abortSignal: abort.signal,
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<TaxDocumentsData>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
};
