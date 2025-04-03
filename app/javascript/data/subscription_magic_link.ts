import { request, ResponseError } from "$app/utils/request";

type SendMagicLinkRequestArgs = {
  emailSource: string;
  subscriptionId: string;
};

export const sendMagicLink = async ({ emailSource, subscriptionId }: SendMagicLinkRequestArgs) => {
  const response = await request({
    method: "POST",
    url: Routes.send_magic_link_subscription_path(subscriptionId),
    accept: "json",
    data: { email_source: emailSource },
  });
  if (!response.ok) {
    throw new ResponseError("Error sending magic link email");
  }
};
