import { cast } from "ts-safe-cast";

import { assertDefined } from "$app/utils/assert";
import { request, ResponseError } from "$app/utils/request";

export type Collaborator = {
  id: string;
  email: string;
  name: string | null;
  avatar_url: string;
  percent_commission: number | null;
  setup_incomplete: boolean;
  products: CollaboratorProduct[];
  invitation_accepted: boolean;
};

type CollaboratorProduct = {
  id: string;
  name: string;
  percent_commission: number | null;
};

export type CollaboratorsData = {
  collaborators: Collaborator[];
  collaborators_disabled_reason: string | null;
  has_incoming_collaborators: boolean;
};

export async function getCollaborators() {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.internal_collaborators_path(),
  });
  if (!response.ok) throw new ResponseError();
  return cast<CollaboratorsData>(await response.json());
}

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

type NewCollaboratorFormData = {
  products: CollaboratorFormProduct[];
  collaborators_disabled_reason: string | null;
};

type EditCollaboratorFormData = NewCollaboratorFormData & {
  id: string;
  email: string;
  name: string;
  avatar_url: string;
  apply_to_all_products: boolean;
  dont_show_as_co_creator: boolean;
  percent_commission: number | null;
  setup_incomplete: boolean;
};

export type CollaboratorFormData = NewCollaboratorFormData | EditCollaboratorFormData;

export async function getEditCollaborator(collaboratorId: string) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.edit_internal_collaborator_path(collaboratorId),
  });
  if (!response.ok) {
    if (response.status === 404) return null;
    throw new ResponseError();
  }
  return cast<EditCollaboratorFormData>(await response.json());
}

export async function getNewCollaborator() {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.new_internal_collaborator_path(),
  });
  if (!response.ok) throw new ResponseError();
  return cast<NewCollaboratorFormData>(await response.json());
}

type SaveCollaboratorResponse = { success: boolean; message?: string };

type SaveCollaboratorPayload = {
  apply_to_all_products: boolean;
  dont_show_as_co_creator: boolean;
  percent_commission: number | null;
  products: {
    id: string;
    percent_commission: number | null;
    dont_show_as_co_creator: boolean;
  }[];
};
type CreateCollaboratorPayload = SaveCollaboratorPayload & {
  email: string;
};
type UpdateCollaboratorPayload = SaveCollaboratorPayload & {
  id: string;
};

export async function addCollaborator(collaborator: CreateCollaboratorPayload) {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_collaborators_path(),
    data: { collaborator },
  });
  const responseData = cast<SaveCollaboratorResponse>(await response.json());
  if (!response.ok) throw new ResponseError(responseData.message);
  return responseData;
}

export async function updateCollaborator(collaborator: UpdateCollaboratorPayload) {
  const collaboratorId = assertDefined(collaborator.id, "Collaborator ID is required");
  const response = await request({
    method: "PATCH",
    accept: "json",
    url: Routes.internal_collaborator_path(collaboratorId),
    data: { collaborator },
  });
  const responseData = cast<SaveCollaboratorResponse>(await response.json());
  if (!response.ok) throw new ResponseError(responseData.message);
  return responseData;
}

export async function removeCollaborator(collaboratorId: string) {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.internal_collaborator_path(collaboratorId),
  });
  if (!response.ok) throw new ResponseError();
}

export async function acceptCollaboratorInvitation(collaboratorId: string) {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_collaborator_invitation_acceptances_path(collaboratorId),
  });
  if (!response.ok) throw new ResponseError();
}

export async function declineCollaboratorInvitation(collaboratorId: string) {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_collaborator_invitation_declines_path(collaboratorId),
  });
  if (!response.ok) throw new ResponseError();
}
