export type Collaborator = {
  id: string;
  email: string;
  name: string | null;
  avatar_url: string;
  percent_commission: number;
  setup_incomplete: boolean;
  products: {
    id: string;
    name: string;
    percent_commission: number;
  }[];
  invitation_accepted: boolean;
};

export type CollaboratorFormProduct = {
  id: string;
  name: string;
  has_another_collaborator: boolean;
  has_affiliates: boolean;
  published: boolean;
  enabled: boolean;
  percent_commission: number | null;
  dont_show_as_co_creator: boolean;
};

export type CollaboratorFormData = {
  email?: string;
  apply_to_all_products: boolean;
  percent_commission: number | null;
  dont_show_as_co_creator: boolean;
  products: CollaboratorFormProduct[];
};

export type CollaboratorPagesSharedProps = {
  collaborators_disabled_reason: string | null;
};

export type CollaboratorFormPageMetaData = {
  default_percent_commission: number;
  min_percent_commission: number;
  max_percent_commission: number;
  max_products_with_affiliates_to_show: number;
  title: string;
};

export type NewPageProps = {
  form_data: CollaboratorFormData;
  page_metadata: CollaboratorFormPageMetaData;
} & CollaboratorPagesSharedProps;

export type EditPageProps = {
  form_data: CollaboratorFormData & { id: string };
  page_metadata: CollaboratorFormPageMetaData;
} & CollaboratorPagesSharedProps;
