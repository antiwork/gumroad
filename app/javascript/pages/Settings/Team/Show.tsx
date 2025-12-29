import { usePage, router } from "@inertiajs/react";
import { cx } from "class-variance-authority";
import * as React from "react";
import { GroupBase, SelectInstance } from "react-select";
import { cast } from "ts-safe-cast";

import {
  ROLES,
  Role,
  MemberInfo,
  TeamInvitation,
  createTeamInvitation,
  deleteMember,
  resendInvitation,
  restoreMember,
  updateMember,
} from "$app/data/settings/team";
import { SettingPage } from "$app/parsers/settings";
import { isValidEmail } from "$app/utils/email";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { Option, Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { Alert } from "$app/components/ui/Alert";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { WithTooltip } from "$app/components/WithTooltip";

const ROLE_TITLES: Record<Role, string> = {
  owner: "Owner",
  accountant: "Accountant",
  admin: "Admin",
  marketing: "Marketing",
  support: "Support",
};

type TeamPageProps = {
  member_infos: MemberInfo[];
  can_invite_member: boolean;
  settings_pages: SettingPage[];
};

export default function TeamPage() {
  const props = cast<TeamPageProps>(usePage().props);

  const options: Option[] = ROLES.map((role) => ({
    id: role,
    label: ROLE_TITLES[role],
  }));

  const refreshMemberInfos = () => {
    router.reload({ only: ["member_infos"] });
  };

  return (
    <SettingsLayout currentPage="team" pages={props.settings_pages}>
      <form>
        {props.can_invite_member ? (
          <AddTeamMembersSection refreshMemberInfos={refreshMemberInfos} options={options} />
        ) : null}
        <TeamMembersSection memberInfos={props.member_infos} refreshMemberInfos={refreshMemberInfos} />
      </form>
    </SettingsLayout>
  );
}

const AddTeamMembersSection = ({
  refreshMemberInfos,
  options,
}: {
  refreshMemberInfos: () => void;
  options: Option[];
}) => {
  const emailUID = React.useId();
  const roleUID = React.useId();

  const emailFieldRef = React.useRef<HTMLInputElement>(null);
  const roleFieldRef = React.useRef<SelectInstance<Option, false, GroupBase<Option>>>(null);

  const [teamInvitation, setTeamInvitation] = React.useState<TeamInvitation>({ email: "", role: null });
  const [errors, setErrors] = React.useState<Map<string, string>>(new Map());

  const updateTeamInvitation = (update: Partial<TeamInvitation>) =>
    setTeamInvitation((prevTeamInvitation) => ({ ...prevTeamInvitation, ...update }));

  const clearError = (errorKey: string) => {
    if (errors.has(errorKey)) {
      const newErrors = new Map(errors);
      newErrors.delete(errorKey);
      setErrors(newErrors);
    }
  };

  const [loading, setLoading] = React.useState(false);

  const onSubmit = asyncVoid(async () => {
    const errors = new Map<string, string>();

    if (!isValidEmail(teamInvitation.email)) {
      errors.set("email", "Please enter a valid email address");
      showAlert("Please enter a valid email address", "error");
      emailFieldRef.current?.focus();
    } else if (!teamInvitation.role) {
      errors.set("role", "Please select a role");
      showAlert("Please select a role", "error");
      roleFieldRef.current?.focus();
    }
    setErrors(errors);
    if (errors.size > 0) return;

    setLoading(true);
    const result = await createTeamInvitation(teamInvitation);
    if (result.success) {
      refreshMemberInfos();
      showAlert("Invitation sent!", "success");
      updateTeamInvitation({ email: "", role: null });
    } else {
      showAlert(result.error_message, "error");
      errors.set("error", result.error_message);
    }
    setErrors(errors);
    setLoading(false);
  });

  return (
    <section className="p-4! md:p-8!">
      <header>
        <h2>Add team members</h2>
        <div>Invite as many team members as you need to help run this account.</div>
        <a href="/help/article/326-teams-and-roles" target="_blank" rel="noreferrer">
          Learn more
        </a>
      </header>
      <div
        style={{
          display: "grid",
          gap: "var(--spacer-3)",
          gridTemplateColumns: "repeat(auto-fit, max(var(--dynamic-grid), 50% - var(--spacer-3) / 2))",
        }}
      >
        <fieldset className={cx({ danger: errors.has("email") })}>
          <legend>
            <label htmlFor={emailUID}>Email</label>
          </legend>
          <input
            id={emailUID}
            type="text"
            ref={emailFieldRef}
            placeholder="Team member's email"
            className="required"
            value={teamInvitation.email}
            onChange={(evt) => {
              updateTeamInvitation({ email: evt.target.value });
              clearError("email");
            }}
          />
        </fieldset>
        <fieldset className={cx({ danger: errors.has("role") })}>
          <legend>
            <label htmlFor={roleUID}>Role</label>
          </legend>
          <Select
            ref={roleFieldRef}
            inputId={roleUID}
            instanceId={roleUID}
            options={options.filter((o) => o.id !== "owner")}
            isMulti={false}
            isClearable={false}
            placeholder="Choose a role"
            value={options.find((o) => o.id === teamInvitation.role) ?? null}
            onChange={(evt) => {
              if (evt !== null) {
                updateTeamInvitation({ role: evt.id });
                clearError("role");
              }
            }}
          />
        </fieldset>
      </div>
      <Button color="primary" className="w-fit" disabled={loading} onClick={onSubmit}>
        {loading ? (
          <>
            <LoadingSpinner color="grey" /> Sending invitation
          </>
        ) : (
          "Send invitation"
        )}
      </Button>
    </section>
  );
};

const TeamMembersSection = ({
  memberInfos,
  refreshMemberInfos,
}: {
  memberInfos: MemberInfo[];
  refreshMemberInfos: () => void;
}) => {
  const currentSeller = useCurrentSeller();
  const [loading, setLoading] = React.useState(false);
  const [confirming, setConfirming] = React.useState<MemberInfo | null>(null);
  const [deletedMember, setDeletedMember] = React.useState<MemberInfo | null>(null);
  const ref = React.useRef<HTMLHeadingElement>(null);

  const handleOptionChange = async ({
    memberInfo,
    selectedOption,
  }: {
    memberInfo: MemberInfo;
    selectedOption: string;
  }) => {
    setDeletedMember(null);
    setLoading(true);
    try {
      switch (selectedOption) {
        case "leave_team": {
          await deleteMember(memberInfo);
          window.location.href = Routes.dashboard_path();
          break;
        }
        case "remove_from_team": {
          await deleteMember(memberInfo);
          refreshMemberInfos();
          setDeletedMember(memberInfo);
          ref.current?.scrollIntoView({ behavior: "smooth" });
          break;
        }
        case "resend_invitation": {
          await resendInvitation(memberInfo);
          refreshMemberInfos();
          showAlert("Invitation sent!", "success");
          break;
        }
        default: {
          const newRole = cast<Role>(selectedOption);
          if (ROLES.includes(newRole) && memberInfo.role !== newRole) {
            await updateMember(memberInfo, newRole);
            refreshMemberInfos();
            showAlert(
              `Role for ${memberInfo.name !== "" ? memberInfo.name : memberInfo.email} has changed to ${ROLE_TITLES[newRole]}`,
              "success",
            );
            break;
          }
        }
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setLoading(false);
  };

  return (
    <section className="p-4! md:p-8!">
      <header>
        <h2 ref={ref}>Team members</h2>
      </header>
      {deletedMember ? (
        <Alert variant="success">
          <div className="flex flex-col justify-between sm:flex-row">
            {deletedMember.name !== "" ? deletedMember.name : deletedMember.email} was removed from team members
            <button
              className="underline"
              type="button"
              onClick={asyncVoid(async () => {
                try {
                  await restoreMember(deletedMember);
                  refreshMemberInfos();
                  showAlert(
                    `${deletedMember.name !== "" ? deletedMember.name : deletedMember.email} was added back to the team`,
                    "success",
                  );
                  setDeletedMember(null);
                } catch (e) {
                  assertResponseError(e);
                  showAlert(e.message, "error");
                }
              })}
            >
              Undo
            </button>
          </div>
        </Alert>
      ) : null}
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Member</TableHead>
            <TableHead>Role</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {memberInfos.map((memberInfo) => (
            <TableRow key={`${memberInfo.type}-${memberInfo.id}`}>
              <TableCell>
                <div style={{ display: "flex", alignItems: "center", gap: "var(--spacer-4)" }}>
                  <img
                    className="user-avatar"
                    style={{ width: "var(--spacer-6)" }}
                    src={memberInfo.avatar_url}
                    alt={`Avatar of ${memberInfo.name}`}
                  />
                  <div style={{ display: "flex", alignItems: "center", gap: "var(--spacer-2)" }}>
                    <div>
                      {memberInfo.name}
                      <small>{memberInfo.email}</small>
                    </div>
                    {memberInfo.is_expired ? (
                      <WithTooltip
                        tip="Invitation has expired. You can resend the invitation from the member's menu options."
                        position="top"
                      >
                        <Icon
                          name="solid-shield-exclamation"
                          style={{ color: "rgb(var(--warning))" }}
                          aria-label="Invitation has expired. You can resend the invitation from the member's menu options."
                        />
                      </WithTooltip>
                    ) : null}
                  </div>
                </div>
              </TableCell>
              <TableCell>
                <div className="flex items-center gap-2">
                  <Select
                    instanceId={memberInfo.id}
                    options={memberInfo.options}
                    onChange={(newOption) => {
                      if (newOption !== null) {
                        void handleOptionChange({ memberInfo, selectedOption: newOption.id });
                      }
                    }}
                    isMulti={false}
                    isClearable={false}
                    isDisabled={loading || memberInfo.options.length === 1}
                    value={memberInfo.options.find((o) => o.id === memberInfo.role) ?? null}
                    className="flex-1"
                  />
                  {memberInfo.leave_team_option ? (
                    <Button color="danger" disabled={loading} onClick={() => setConfirming(memberInfo)}>
                      {memberInfo.leave_team_option.label}
                    </Button>
                  ) : null}
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
      {confirming ? (
        <Modal
          open
          onClose={() => setConfirming(null)}
          title="Leave team?"
          footer={
            <>
              <Button disabled={loading} onClick={() => setConfirming(null)}>
                Cancel
              </Button>
              <Button
                color="danger"
                disabled={loading}
                onClick={asyncVoid(async () => {
                  setLoading(true);
                  await handleOptionChange({ memberInfo: confirming, selectedOption: "leave_team" });
                  setConfirming(null);
                })}
              >
                {loading ? (
                  <>
                    <LoadingSpinner color="grey" /> <h4>Leaving team</h4>
                  </>
                ) : (
                  <h4>Yes, leave team</h4>
                )}
              </Button>
            </>
          }
        >
          Are you sure you want to leave {currentSeller?.name || ""} team? Once you leave the team you will no longer
          have access.
        </Modal>
      ) : null}
    </section>
  );
};
