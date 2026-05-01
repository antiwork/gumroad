import { usePage } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Pill } from "$app/components/ui/Pill";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

type AdminApiToken = {
  external_id: string;
  actor: {
    id: number | null;
    name: string | null;
    email: string | null;
  };
  kind: "CLI" | "Service" | "Legacy";
  created_at: string;
  last_used_at: string | null;
  expires_at: string | null;
  revoke_path: string;
};

type PageProps = {
  tokens: AdminApiToken[];
  authenticity_token: string;
};

const formatDate = (date: string | null) => (date ? new Date(date).toLocaleString() : "Never");
const typeColor: Record<AdminApiToken["kind"], React.ComponentProps<typeof Pill>["color"]> = {
  CLI: undefined,
  Service: "primary",
  Legacy: "warning",
};
const actorName = (actor: AdminApiToken["actor"]) => actor.name ?? actor.email ?? "Unknown user";

const AdminApiTokens = () => {
  const { tokens, authenticity_token: authenticityToken } = usePage<PageProps>().props;

  return (
    <section className="max-w-7xl overflow-x-auto">
      {tokens.length > 0 ? (
        <Table className="lg:min-w-[64rem]">
          <TableHeader>
            <TableRow>
              <TableHead className="lg:w-56">Token ID</TableHead>
              <TableHead className="lg:w-64">Actor</TableHead>
              <TableHead className="lg:w-28">Type</TableHead>
              <TableHead className="lg:w-44">Created</TableHead>
              <TableHead className="lg:w-44">Last used</TableHead>
              <TableHead className="lg:w-44">Expires</TableHead>
              <TableHead className="lg:w-px">
                <span className="sr-only">Actions</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {tokens.map((token) => (
              <TableRow key={token.external_id}>
                <TableCell>
                  <code className="whitespace-nowrap">{token.external_id}</code>
                </TableCell>
                <TableCell>
                  <div>{actorName(token.actor)}</div>
                  {token.actor.email ? (
                    <div className="max-w-64 truncate text-xs text-muted">{token.actor.email}</div>
                  ) : null}
                </TableCell>
                <TableCell className="lg:whitespace-nowrap">
                  <Pill size="small" color={typeColor[token.kind]}>
                    {token.kind}
                  </Pill>
                </TableCell>
                <TableCell>
                  <span className="whitespace-nowrap">{formatDate(token.created_at)}</span>
                </TableCell>
                <TableCell>
                  <span className="whitespace-nowrap">{formatDate(token.last_used_at)}</span>
                </TableCell>
                <TableCell>
                  <span className="whitespace-nowrap">{formatDate(token.expires_at)}</span>
                </TableCell>
                <TableCell className="lg:whitespace-nowrap">
                  <form action={token.revoke_path} method="post">
                    <input type="hidden" name="authenticity_token" value={authenticityToken} />
                    <Button type="submit" color="danger" size="sm" className="whitespace-nowrap">
                      Revoke
                    </Button>
                  </form>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      ) : (
        <p>No admin API tokens.</p>
      )}
    </section>
  );
};

export default AdminApiTokens;
