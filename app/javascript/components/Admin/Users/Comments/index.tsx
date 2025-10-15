import React from "react";

import AdminCommentableComments from "$app/components/Admin/Commentable";
import type { User } from "$app/components/Admin/Users/User";

type AdminUserCommentsProps = {
  user: User;
};

const AdminUserComments = ({ user }: AdminUserCommentsProps) => (
  <AdminCommentableComments endpoint={Routes.admin_user_comments_path(user.id)} commentableType="user" />
);

export default AdminUserComments;
