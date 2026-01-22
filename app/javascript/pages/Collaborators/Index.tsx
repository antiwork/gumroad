import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import type { Collaborator, CollaboratorPagesSharedProps } from "$app/data/collaborators";
import { formatCommission, formatProductNames } from "$app/utils/collaboratorFormatters";

import { Button } from "$app/components/Button";
import CollaboratorDetailsSheet from "$app/components/Collaborators/CollaboratorDetailsSheet";
import { Layout } from "$app/components/Collaborators/Layout";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { showAlert } from "$app/components/server-components/Alert";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/collaborators.png";

type CollaboratorsPageProps = {
  collaborators: Collaborator[];
  has_incoming_collaborators: boolean;
} & CollaboratorPagesSharedProps;

const CollaboratorsPage = () => {
  const loggedInUser = useLoggedInUser();

  const { collaborators, collaborators_disabled_reason, has_incoming_collaborators } = cast<CollaboratorsPageProps>(
    usePage().props,
  );
  const [selectedCollaborator, setSelectedCollaborator] = React.useState<Collaborator | null>(null);

  const deleteForm = useForm({});

  const remove = (collaboratorId: string) => {
    deleteForm.delete(Routes.collaborator_path(collaboratorId), {
      only: ["collaborators", "flash", "has_incoming_collaborators"],
      onSuccess: () => {
        setSelectedCollaborator(null);
      },
      onError: () => {
        showAlert("Failed to remove the collaborator.", "error");
      },
    });
  };

  const disableActions = !loggedInUser?.policies.collaborator.update || deleteForm.processing;

  return (
    <Layout
      title="Cộng tác viên"
      selectedTab="collaborators"
      showTabs={has_incoming_collaborators}
      headerActions={
        <WithTooltip position="bottom" tip={collaborators_disabled_reason}>
          <NavigationButtonInertia
            href={Routes.new_collaborator_path()}
            color="accent"
            disabled={disableActions || collaborators_disabled_reason !== null}
          >
            Thêm cộng tác viên
          </NavigationButtonInertia>
        </WithTooltip>
      }
    >
      {collaborators.length > 0 ? (
        <>
          <section className="p-4 md:p-8">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Tên</TableHead>
                  <TableHead>Sản phẩm</TableHead>
                  <TableHead>Hoa hồng</TableHead>
                  <TableHead>Trạng thái</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>

              <TableBody>
                {collaborators.map((collaborator) => (
                  <TableRow
                    key={collaborator.id}
                    selected={collaborator.id === selectedCollaborator?.id}
                    onClick={() => setSelectedCollaborator(collaborator)}
                  >
                    <TableCell>
                      <div className="flex items-center gap-4">
                        <img
                          className="user-avatar"
                          src={collaborator.avatar_url}
                          style={{ width: "var(--spacer-6)" }}
                          alt={`Avatar of ${collaborator.name || "Collaborator"}`}
                        />
                        <div>
                          <span className="whitespace-nowrap">{collaborator.name || "Collaborator"}</span>
                          <small className="line-clamp-1">{collaborator.email}</small>
                        </div>
                        {collaborator.setup_incomplete ? (
                          <WithTooltip tip="Không nhận được khoản thanh toán" position="top">
                            <Icon
                              name="solid-shield-exclamation"
                              style={{ color: "rgb(var(--warning))" }}
                              aria-label="Không nhận được khoản thanh toán"
                            />
                          </WithTooltip>
                        ) : null}
                      </div>
                    </TableCell>
                    <TableCell>
                      <span className="line-clamp-2">{formatProductNames(collaborator)}</span>
                    </TableCell>
                    <TableCell className="whitespace-nowrap">{formatCommission(collaborator)}</TableCell>
                    <TableCell className="whitespace-nowrap">
                      {collaborator.invitation_accepted ? <>Đã chấp nhận</> : <>Đang chờ xử lý</>}
                    </TableCell>
                    <TableCell onClick={(e) => e.stopPropagation()}>
                      <div className="flex flex-wrap gap-3 lg:justify-end">
                        <NavigationButtonInertia
                          href={Routes.edit_collaborator_path(collaborator.id)}
                          aria-label="Chỉnh sửa"
                          disabled={disableActions}
                        >
                          <Icon name="pencil" />
                        </NavigationButtonInertia>

                        <Button
                          type="submit"
                          color="danger"
                          onClick={() => remove(collaborator.id)}
                          aria-label="Xóa"
                          disabled={disableActions}
                        >
                          <Icon name="trash2" />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </section>
          {selectedCollaborator ? (
            <CollaboratorDetailsSheet
              collaborator={selectedCollaborator}
              onClose={() => setSelectedCollaborator(null)}
              showSetupWarning={selectedCollaborator.setup_incomplete}
              actions={
                <>
                  <NavigationButtonInertia
                    href={Routes.edit_collaborator_path(selectedCollaborator.id)}
                    className="flex-1"
                    aria-label="Chỉnh sửa"
                    disabled={disableActions}
                  >
                    Chỉnh sửa
                  </NavigationButtonInertia>
                  <Button
                    className="flex-1"
                    color="danger"
                    aria-label="Xóa"
                    onClick={() => remove(selectedCollaborator.id)}
                    disabled={disableActions}
                  >
                    {deleteForm.processing ? "Đang xóa..." : "Xóa"}
                  </Button>
                </>
              }
            />
          ) : null}
        </>
      ) : (
        <section className="p-4 md:p-8">
          <Placeholder>
            <PlaceholderImage src={placeholder} />
            <h2>Chưa có cộng tác viên nào</h2>
            <h4>Chia sẻ doanh thu của bạn với những người đã giúp tạo ra sản phẩm của bạn.</h4>
            <a href="/help/article/341-collaborations" target="_blank" rel="noreferrer">
              Tìm hiểu thêm về cộng tác viên
            </a>
          </Placeholder>
        </section>
      )}
    </Layout>
  );
};

export default CollaboratorsPage;
