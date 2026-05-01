import { usePage } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";

type PageProps = {
  actor: {
    name: string;
    email: string;
  };
  callback: string;
  state: string;
  code_challenge: string;
  authorization_request: string;
  authorize_path: string;
  authenticity_token: string;
};

const AdminCliAuthorization = () => {
  const {
    actor,
    callback,
    state,
    code_challenge: codeChallenge,
    authorization_request: authorizationRequest,
    authorize_path: authorizePath,
    authenticity_token: authenticityToken,
  } = usePage<PageProps>().props;

  return (
    <section className="max-w-2xl">
      <div className="flex flex-col gap-6">
        <div className="flex flex-col gap-2">
          <h2>Authorize the Gumroad CLI on this machine?</h2>
          <p>
            The CLI will be able to perform admin operations as {actor.name} ({actor.email}) until the token expires or
            is revoked.
          </p>
        </div>

        <form className="flex flex-col gap-4" action={authorizePath} method="post">
          <input type="hidden" name="authenticity_token" value={authenticityToken} />
          <input type="hidden" name="callback" value={callback} />
          <input type="hidden" name="state" value={state} />
          <input type="hidden" name="code_challenge" value={codeChallenge} />
          <input type="hidden" name="authorization_request" value={authorizationRequest} />
          <Button type="submit" color="primary" className="w-fit">
            Authorize CLI
          </Button>
        </form>
      </div>
    </section>
  );
};

export default AdminCliAuthorization;
