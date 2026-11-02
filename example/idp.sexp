; The identity provider's users, groups, OIDC clients and APIs, which
; serai idp keeps Pocket ID in line with. Resources live in Pocket ID but
; not named here are reported and left alone; a declared resource is
; exactly what it says (its groups, callback URLs, permissions, grants and
; claims). Passkeys and client secrets are never declared.
((url https://id.example.org)
 (groups ((admins (friendly_name Admins))
          (family (friendly_name Family) (claims ((household north))))))
 (users ((alice (email alice@example.org) (display_name Alice) (admin)
                (groups (admins family)) (claims ((ledger_account a-001))))
         (bob (email bob@example.org) (first_name Bob) (groups (family)))))
 (clients ((hello (name Hello) (callback_urls (https://hello.example.org/auth/callback))
                  (public) (pkce) (allowed_groups (family)))
           (logs (name Logs) (description "Log viewer behind oauth2-proxy")
                 (callback_urls (https://logs.example.org/oauth2/callback))
                 (allowed_groups (admins)))))
 (apis ((https://ledger.example.org/mcp
         (name Ledger)
         (permissions ((ledger:read (name "Read the ledger"))
                       (ledger:write (name "Write the ledger")
                                     (description "Create and change entries"))))
         ; CIMD on, for these permissions only.
         (cimd (ledger:read))
         (grants ((hello (user_delegated (ledger:read)))))))))
