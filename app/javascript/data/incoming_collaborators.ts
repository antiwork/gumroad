import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export type IncomingCollaboratorsData = {
  collaborators: IncomingCollaborator[];
  collaborators_disabled_reason: string | null;
};

export type IncomingCollaborator = {
  id: string;
  seller_email: string;
  seller_name: string;
  seller_avatar_url: string;
  apply_to_all_products: boolean;
  affiliate_percentage: number;
  dont_show_as_co_creator: boolean;
  invitation_accepted: boolean;
  products: {
    id: string;
    url: string;
    name: string;
    affiliate_percentage: number;
    dont_show_as_co_creator: boolean;
  }[];
};

export const getIncomingCollaborators = async () => {
  const response = await request({
    method: "GET",
    url: Routes.internal_collaborators_incomings_path(),
    accept: "json",
  });

  if (!response.ok) throw new ResponseError();

  return cast<IncomingCollaboratorsData>(await response.json());
};
