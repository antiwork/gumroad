export type UtmLinkDestinationOption = {
  id: string;
  label: string;
  url: string;
};

type UtmLinkFormStaticMetaData = {
  destination_options: UtmLinkDestinationOption[];
  utm_fields_values: {
    campaigns: string[];
    mediums: string[];
    sources: string[];
    terms: string[];
    contents: string[];
  };
  short_url_prefix: string;
  short_url_protocol: string;
};

export type UtmLinkFormData = {
  title: string;
  destination_option: UtmLinkDestinationOption | null;
  target_resource_type: string | null;
  target_resource_id: string | null;
  permalink: string;
  utm_source: string | null;
  utm_medium: string | null;
  utm_campaign: string | null;
  utm_term: string | null;
  utm_content: string | null;
};

export type UtmLinkNewPageProps = {
  context: UtmLinkFormStaticMetaData;
  utm_link: UtmLinkFormData;
};

export type UtmLinkEditPageProps = {
  context: UtmLinkFormStaticMetaData;
  utm_link: UtmLinkFormData & { id: string };
};
