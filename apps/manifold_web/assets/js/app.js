import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import * as DuskmoonHooks from "phoenix_duskmoon/hooks";

// WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#71
// Importing @duskmoon-dev/elements/register crashes duskmoon_bundler 9.9.2.
// The Milestone 1 operational views do not render Duskmoon custom elements directly.
let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: DuskmoonHooks,
});

liveSocket.connect();
window.liveSocket = liveSocket;
