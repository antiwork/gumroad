import { usePage } from "@inertiajs/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

type CliToken = {
  external_id: string;
  created_at: string;
  last_used_at: string | null;
  expires_at: string | null;
  revoke_path: string;
};

type PageProps = {
  tokens: CliToken[];
  authenticity_token: string;
};

const formatDate = (date: string | null) => (date ? new Date(date).toLocaleString() : "Never");

const AdminCliTokens = () => {
  const { tokens, authenticity_token: authenticityToken } = usePage<PageProps>().props;

  return (
    <section className="max-w-5xl">
      {tokens.length > 0 ? (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Token</TableHead>
              <TableHead>Created</TableHead>
              <TableHead>Last used</TableHead>
              <TableHead>Expires</TableHead>
              <TableHead>
                <span className="sr-only">Actions</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {tokens.map((token) => (
              <TableRow key={token.external_id}>
                <TableCell>
                  <code>{token.external_id}</code>
                </TableCell>
                <TableCell>{formatDate(token.created_at)}</TableCell>
                <TableCell>{formatDate(token.last_used_at)}</TableCell>
                <TableCell>{formatDate(token.expires_at)}</TableCell>
                <TableCell>
                  <form action={token.revoke_path} method="post">
                    <input type="hidden" name="authenticity_token" value={authenticityToken} />
                    <Button type="submit" color="danger" size="sm">
                      Revoke
                    </Button>
                  </form>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      ) : (
        <p>No active CLI tokens.</p>
      )}
    </section>
  );
};

export default AdminCliTokens;
