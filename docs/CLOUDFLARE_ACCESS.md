# Cloudflare Access sign-in

A server behind [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/access-controls/) can be reached by signing in through the browser, with any login method the Access application offers (Google, an emailed one-time PIN, other identity providers, passkeys). Turn it on in **Settings ▸ <server> ▸ Connection ▸ Cloudflare Access**, click **Apply**, then **Sign In…**.

The app uses Cloudflare's [Managed OAuth](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/managed-oauth/), the sign-in Cloudflare documents for apps and agents. For machine access without a person, use a service token instead: add its `CF-Access-Client-Id` and `CF-Access-Client-Secret` under **Custom Headers**.

## Put Transmission behind Access

You need a domain on Cloudflare. Transmission answers RPC at `/transmission/rpc` on its RPC port (9091 by default). These steps follow Cloudflare's guides to [self-hosted applications](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/) and [tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/).

1. **Create the Access application first**, so the hostname is never published unprotected. In Zero Trust ▸ **Access controls** ▸ **Applications**, choose **Create new application** ▸ **Self-hosted and private**, then **Add public hostname**:
   - **Subdomain:** e.g. `transmission`; **Domain:** your domain; **Path:** `transmission/rpc`.
   - **Access policies:** an Allow policy for the people who may use it (applications deny by default). For a service token, add a **Service Auth** policy too.
   - **Login methods:** the identity providers to offer.
2. **Turn on Managed OAuth** on the application's **Additional settings** tab, with the values under [Access settings it needs](#access-settings-it-needs).
3. **Publish Transmission through a tunnel.** In **Networking** ▸ **Tunnels**, choose **Create a tunnel**, then install and run the connector it shows on the machine running Transmission (or one that can reach it). On the tunnel's **Routes** tab, choose **Add route** ▸ **Published application**: the same subdomain and domain, and **Service URL** `http://localhost:9091` (the address and port the connector uses to reach Transmission).
4. **Let Transmission accept the proxied requests** (in its `settings.json`, with the daemon stopped):
   - If it answers `421 Misdirected Request`, add the public hostname to `rpc-host-whitelist`.
   - If it answers `403` because of the client address and the connector runs on another machine, add the connector's address to `rpc-whitelist`.
   - Keep `rpc-authentication-required` with your username and password: Access sits in front of Transmission's own login, not in place of it.
5. **Add the server in the app:** **Host** = the public hostname, **Port** 443, **Use HTTPS** on, **RPC Path** `/transmission/rpc`, and Transmission's username and password. Check **Sign in with Cloudflare Access**, click **Apply**, then **Sign In…**.

The Access application covers only `/transmission/rpc`. Anything else the tunnel publishes on that hostname, such as Transmission's web interface at `/transmission/web/`, needs its own Access application or should stay unpublished.

## Access settings it needs

On the Access application that protects the RPC path (Zero Trust ▸ Access controls ▸ Applications ▸ the app ▸ **Additional settings**):

| Setting | Value |
|---|---|
| **Managed OAuth** | On |
| **Allow loopback clients** | On (the app's redirect is `http://127.0.0.1:<port>/callback`) |
| **Enable Binding Cookie** (Cookie settings) | **Off**. With it on, Access refuses the app's OAuth tokens. |
| **Access token lifetime** | 5–15 minutes (15 minutes by default). The app renews it in the background. |
| **Grant session duration** | 1–2 weeks. How long the app may keep renewing before you sign in again in the browser. |

These lifetimes follow Cloudflare's [recommended configuration for CLI and agent use cases](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/managed-oauth/#managed-oauth-settings) (a callout under *Managed OAuth settings*): a short access token paired with a long grant session. The app renews the token silently with the refresh token, Access re-checks its policies on every renewal, and the browser is needed only when the grant ends. With a 15-minute token and a 2-week grant, you sign in once every two weeks.

Policies and login methods are unchanged: the OAuth sign-in goes through the same policies and identity providers as a browser login.

## How it works

1. **Discover.** A request without a token gets `401` with `WWW-Authenticate: Bearer realm="OAuth", …, resource_metadata="https://<host>/.well-known/cloudflare-access-protected-resource/…"`. The resource metadata (on the same host) names the authorization server, which must be HTTPS on a `*.cloudflareaccess.com` team domain; its metadata at `/.well-known/oauth-authorization-server` must offer PKCE S256, public clients and registration, with endpoints on its own host. If Access redirects to its login page instead, Managed OAuth is off, and the app says so.
2. **Register.** The first sign-in registers the app as a public client (no secret) with a `127.0.0.1` redirect. Later sign-ins reuse that registration and its port; if the port is busy, the app picks another and registers again.
3. **Sign in.** The default browser opens the authorization page with PKCE (S256), a random `state` and the `resource`. After the login, Access shows an **Authorize Client** page naming the app ("Transmission Remote") and its `127.0.0.1` redirect, with Deny / Allow. When you finish, the browser returns to the app's short-lived listener on `127.0.0.1`. Its page, headed with the app's icon and name in the same card layout as Access's pages, says whether the sign-in worked; close the tab yourself (browsers don't let a page close a tab it didn't open).
4. **Exchange.** The code is exchanged for an access token and a refresh token.

The access token is sent as `cf-access-token` on every request, which Access accepts, so `Authorization` stays free for Transmission's own username and password. It goes only to the HTTPS host it was issued for; a LAN or other fallback host of the same server never sees it.

### Renewal and expiry

- The access token is renewed with the refresh token 30 seconds before it expires, and whenever Access refuses a token the app sent (the request is then retried once). Access rotates the refresh token on each renewal; the app runs one renewal at a time per server.
- When renewal fails because the grant has ended (or was revoked), the app forgets the tokens and the main window asks once: **Sign In…** / **Not Now**. The browser never opens without a click.
- **Sign Out** revokes both tokens with Access and forgets them, keeping the app's registration for the next sign-in.

## Security notes

- **At rest:** tokens are kept in the login Keychain (service `com.nickvance.transmission-remote-mac.cloudflare-access`, one item per server), never in `preferences.json`. Removing a server removes its item.
- **In transit:** HTTPS only. The token goes only to the host it was issued for.
- **The redirect:** the listener binds `127.0.0.1` only, answers one `/callback`, and the `state` must match; PKCE means an intercepted code is useless without the verifier.
- **Cookies:** no sign-in or RPC request sends or stores cookies.
- **Logging:** tokens are never logged or shown.
- **Binding Cookie:** turning it off removes one defence against a stolen browser cookie for this application. Keep the application scoped to the RPC path.

## Manual test checklist

Set-up: the Access application in front of the RPC path with the settings above; a policy that allows you; Google and One-time PIN login methods. In Settings, the server's Host is the Access hostname with **Use HTTPS** on, and Transmission's username and password filled in.

1. **Baseline:** `curl -i -X POST https://<host>/transmission/rpc` answers `401` with a `Bearer realm="OAuth"` challenge. Test Connection reports "Cloudflare Access sign-in needed".
2. **Turn it on:** check **Sign in with Cloudflare Access** and click **Apply**. The status reads "Not signed in." and **Sign In…** is enabled.
3. **Google:** click **Sign In…**. Your default browser (not a window in the app) opens the Access login page. Choose Google and finish. The tab shows Transmission Remote's "Signed in" page.
   - Settings: "Signed in · Today at <time>. Access renews the session automatically until it ends."
   - Test Connection: "Connection succeeded … Transmission <version>".
4. **Storage:** Keychain Access has a "Transmission Remote Cloudflare Access session" item. `preferences.json` contains `"useCloudflareAccess": true` and no token.
5. **Renewal:** wait past the access token lifetime, then use the app or press Test Connection. It still works, with no browser. The Keychain item's modification time moves.
6. **Relaunch:** quit and reopen the app. It connects without the browser.
7. **End of grant:** wait past the grant session duration (or revoke your session in the dashboard). The main window asks once to sign in again; **Sign In…** works.
8. **Sign Out:** click **Sign Out**. The status reads "Not signed in."; the next request needs a sign-in.
9. **Email code:** sign in choosing **One-time PIN**: enter your email, then the code. Repeat steps 3–8.
10. **Edge cases:**
    - Click **Sign In…**, close the browser tab, then **Cancel**: back to "Not signed in.", nothing stored.
    - Click **Sign In…** and do nothing for 5 minutes: "Sign-in timed out waiting for the browser."
    - An email the policy doesn't allow: Access refuses in the browser; **Cancel** in the app.
    - Click **Deny** on the Authorize Client page: the tab says the sign-in didn't complete, and the app shows why.
    - **Copy Link** copies the sign-in URL for another browser.
    - Turn Managed OAuth off: **Sign In…** explains that it needs to be on.
11. **Fallback hosts:** Host `<LAN address>, https://<access host>`: on the LAN the app connects directly; with the LAN address unreachable it fails over to the Access host with the token. (Unit tests check the LAN host never receives the token.)
