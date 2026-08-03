import React from "react";

import AdminAction from "$app/components/Admin/ActionButton";
import { type User } from "$app/components/Admin/Users/User";

type DisableContentModerationActionProps = {
  user: User;
};

const DisableContentModerationAction = ({
  user: { external_id, content_moderation_disabled },
}: DisableContentModerationActionProps) =>
  content_moderation_disabled ? (
    <AdminAction
      label="Enable content moderation"
      url={Routes.toggle_content_moderation_disabled_admin_user_path(external_id)}
      confirm_message={`Are you sure you want to re-enable content moderation for user ${external_id}?`}
      done="Disable content moderation"
      success_message="Content moderation enabled."
    />
  ) : (
    <AdminAction
      label="Disable content moderation"
      url={Routes.toggle_content_moderation_disabled_admin_user_path(external_id)}
      confirm_message={`Are you sure you want to disable content moderation for user ${external_id}? Every product they create from now on skips moderation, and the account is marked adult.`}
      done="Enable content moderation"
      success_message="Content moderation disabled and account marked as adult."
    />
  );

export default DisableContentModerationAction;
